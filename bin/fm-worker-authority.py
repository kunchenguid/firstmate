#!/usr/bin/env python3
"""Issue exact release receipts from ordinary local Firstmate authorities."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import unicodedata


ROOT = Path(__file__).resolve().parent.parent


AUTHORITY_SCHEMA = "fm.worker-authority/v1"
RELEASE_SCHEMA = "fm.worker-release/v2"
PI_ACCOUNT_HOME_TOOL = ROOT / "bin" / "fm-pi-account-home.py"
REQUIRED_HEADINGS = (
    "## Summary", "## What changed", "## Verification", "## Visual evidence",
    "## Artifacts", "## Follow-ups",
)

# Secondmate compartment evidence (R2/R3 design B.7). The five receipt names
# and the fm.worker-release/v2 shape are IDENTICAL to the ordinary mode - the
# lifecycle's release_receipt and verify_release_against_worker stay
# unmodified - only what each receipt PROVES changes, and the mode is selected
# by the CONTROLLER-OWNED worker role (the task metadata's kind must agree,
# but never decides on its own):
#   endpoint -> the compartment monitor pane is absent (same backend oracle).
#   report   -> session closeout: the monitor's terminal status file, the
#               chained close ack in its durable state, and the ordered
#               completion.md contract (report_evidence, reused verbatim).
#   landing  -> every chained outbox bundle landed into the local secondmate
#               home worktree, or provably none, over a chain verified BY
#               CONTENT against a CONTROLLER-OWNED tip, plus the same lineage
#               tether the ordinary lane applies.
#   account  -> unchanged.
#   worktree -> the secondmate home is quiesced: exact repository root, no
#               uncommitted or untracked work, no unlanded outbox bundles.
#               Children are deliberately NOT consulted here - command_release
#               owns the children-quiesced refusal under the controller lock.
#
# The durable shapes below bind to bin/fm-secondmate-cloud-monitor.{sh,py}
# (branch fm/secondmate-cloud-monitor): the terminal status file
# state/<task>.cloud-secondmate-status holds one of closed|idle|ttl-exhausted;
# the durable monitor state state/<task>.cloud-secondmate-state.json carries
# last_summary {reason, legs_completed}, landed_bundles, kept_bundles - all of
# it monitor-local and therefore NEVER the anchor for a landing proof; the
# mailbox state/<task>.cloud-mailbox holds the collected chained outbox
# (<seq8>-<sha256>.json messages, bundle-<seq8>-<sha256>.bundle bundles, and
# a sticky .chain-break marker on a refused chain).
SECONDMATE_TERMINAL_ACKS = {
    # terminal status line -> the leg-summary reason that acknowledges it
    "closed": "close",
    "idle": "idle",
    "ttl-exhausted": "wall",
}
SECONDMATE_LEG_SUMMARY_KIND = "fm.secondmate-leg-summary/v1"
SECONDMATE_MESSAGE_NAME = re.compile(r"^([0-9]{8})-([0-9a-f]{64})\.json$")
SECONDMATE_GENESIS_CHAIN_DIGEST = "0" * 64
SECONDMATE_HEX64 = re.compile(r"^[0-9a-f]{64}$")
SECONDMATE_BUNDLE_NAME = re.compile(r"^bundle-[0-9]{8}-([0-9a-f]{64})\.bundle$")
SECONDMATE_MAX_MESSAGE_BYTES = 256 * 1024
SECONDMATE_MAX_BUNDLE_BYTES = 256 * 1024 * 1024
SECONDMATE_MAX_STATE_BYTES = 16 * 1024 * 1024


class AuthorityError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def git(path, *args):
    result = subprocess.run(
        ["git", "-C", str(path)] + list(args), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise AuthorityError("git authority failed: {}".format(result.stderr.strip()))
    return result.stdout.strip()


def meta(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    return values


def exactly(values, key):
    entries = values.get(key, [])
    if len(entries) != 1 or not entries[0]:
        raise AuthorityError("task metadata {} identity is not exact".format(key))
    return entries[0]


def receipt(name, task, generation, assignment, evidence):
    value = {
        "schema": AUTHORITY_SCHEMA,
        "authority": name,
        "task": task,
        "task_generation": generation,
        "assignment_generation": assignment,
        "verdict": "proved",
        "evidence_digest": hashlib.sha256(evidence).hexdigest(),
    }
    value["receipt_digest"] = digest(value)
    return value


def endpoint_evidence(home, task, values):
    backend = values.get("backend", ["tmux"])[0]
    target = exactly(values, "window")
    expected = "fm-{}".format(task)
    helper = ROOT / "bin" / "fm-backend.sh"
    script = '. "$1"; fm_backend_target_state "$2" "$3" "$4" "${5:-}"'
    result = subprocess.run(
        ["bash", "-c", script, "_", str(helper), backend, target, expected,
         values.get("tmux_session_target", [""])[0]],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, "FM_HOME": str(home), "FM_ROOT": str(home)},
    )
    endpoint_state = result.stdout.strip()
    if result.returncode == 0 and endpoint_state == "absent":
        return "{}\0{}\0{}\0absent".format(backend, target, expected).encode()
    # A cloud endpoint is only the local tracking monitor. Once the exact
    # digest-bound return has reached local custody it has no guest process or
    # steering authority left, and release must not wait on its own process to
    # disappear before it can free the remote lease. The terminal status is
    # produced only after report and branch custody, and unknown still refuses.
    placement = values.get("placement", [])
    if result.returncode == 0 and endpoint_state == "present" and placement == ["azure"]:
        status = home / "state" / (task + ".status")
        if status.is_symlink() or not status.is_file():
            raise AuthorityError("cloud endpoint authority has no local terminal custody status")
        lines = [line.strip() for line in status.read_text(encoding="utf-8").splitlines() if line.strip()]
        if not lines or not re.match(r"^(done|failed):", lines[-1]):
            raise AuthorityError("cloud endpoint authority has no local terminal custody status")
        return "{}\0{}\0{}\0cloud-return-localized".format(backend, target, expected).encode()
    raise AuthorityError("endpoint authority did not prove the exact task endpoint absent or return-localized")


def report_evidence(home, task, kind="ship"):
    report_name = "report.md" if kind == "scout" else "completion.md"
    path = home / "data" / task / report_name
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise AuthorityError("completion report authority is absent, redirected, or oversized")
    content = path.read_bytes()
    text = content.decode("utf-8")
    positions = [text.find(heading) for heading in REQUIRED_HEADINGS]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise AuthorityError("completion report authority lacks the exact ordered contract headings")
    for index, heading in enumerate(REQUIRED_HEADINGS):
        start = positions[index] + len(heading)
        end = positions[index + 1] if index + 1 < len(positions) else len(text)
        if not any(
            character.isalnum() or unicodedata.category(character).startswith("S")
            for character in text[start:end]
        ):
            raise AuthorityError("completion report authority has an empty required section")
    return content


def worktree_evidence(task, values):
    worktree = Path(exactly(values, "worktree")).resolve()
    if worktree.is_symlink() or not worktree.is_dir() or Path(git(worktree, "rev-parse", "--show-toplevel")).resolve() != worktree:
        raise AuthorityError("worktree authority is not the exact repository root")
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all"):
        raise AuthorityError("writable worktree authority is dirty")
    common = Path(git(worktree, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = (worktree / common).resolve()
    return "{}\0{}\0{}".format(worktree, common.resolve(), git(worktree, "rev-parse", "HEAD")).encode(), worktree


def cloud_return_evidence(home, task, generation, assignment, kind, worktree, repository_generation):
    """Prove local custody before releasing remote worker capacity.

    This is intentionally not ordinary forge landing. The returned commits
    remain protected by the ordinary task branch and later teardown gate; this
    receipt proves only that deleting the worker cannot delete the last copy.
    """
    result_path = home / "state" / (task + ".worker-result.json")
    bundle_path = home / "state" / (task + ".cloud-outcome") / "outcome.bundle"
    manifest_path = home / "data" / task / "cloud-return.json"
    for path, label, limit in (
        (result_path, "result", 8 * 1024 * 1024),
        (bundle_path, "bundle", 256 * 1024 * 1024),
        (manifest_path, "manifest", 1024 * 1024),
    ):
        if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= limit:
            raise AuthorityError("cloud return {} custody is absent, redirected, or oversized".format(label))
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if result.get("schema") != "fm.worker-execution-result/v1":
        raise AuthorityError("cloud return result schema is not supported")
    unsigned = dict(result)
    supplied = unsigned.pop("result_digest", None)
    if supplied != digest(unsigned):
        raise AuthorityError("cloud return result digest is not exact")
    expected = {
        "task": task,
        "task_generation": generation,
        "assignment_generation": assignment,
        "repository_generation": repository_generation,
        "return_present": True,
    }
    for field, value in expected.items():
        if result.get(field) != value:
            raise AuthorityError("cloud return result {} binding differs".format(field))
    bundle = bundle_path.read_bytes()
    if result.get("outcome_bytes") != len(bundle) or result.get("outcome_sha256") != hashlib.sha256(bundle).hexdigest():
        raise AuthorityError("cloud return bundle differs from the digest-bound result")
    manifest = manifest_path.read_bytes()
    if result.get("return_manifest_sha256") != hashlib.sha256(manifest).hexdigest():
        raise AuthorityError("cloud return manifest differs from the digest-bound result")
    manifest_value = json.loads(manifest.decode("utf-8"))
    manifest_expected = {
        "schema": "fm.worker-return/v1",
        "task": task,
        "task_generation": generation,
        "assignment_generation": assignment,
        "request_digest": result.get("request_digest"),
        "repository_generation": repository_generation,
        "kind": kind,
        "report_required": True,
        "report_path": "data/{}/{}".format(
            task, "report.md" if kind == "scout" else "completion.md",
        ),
        "status_path": "state/{}.status".format(task),
        "visuals_path": "data/{}/visuals".format(task),
        "branch": "" if kind == "scout" else "fm/{}".format(task),
        "outcome_commits": result.get("outcome_commits"),
        "outcome_tip": result.get("outcome_tip"),
        "uncommitted_changes": result.get("outcome_uncommitted_changes"),
    }
    for field, value in manifest_expected.items():
        if manifest_value.get(field) != value:
            raise AuthorityError("cloud return manifest {} binding differs".format(field))
    artifacts = manifest_value.get("artifacts")
    if not isinstance(artifacts, dict):
        raise AuthorityError("cloud return manifest artifact bindings are malformed")
    status_path = home / "state" / (task + ".status")
    if status_path.is_symlink() or not status_path.is_file():
        raise AuthorityError("cloud return has no local terminal status")
    status_lines = [line.strip() for line in status_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not status_lines or not re.match(r"^(done|failed):", status_lines[-1]):
        raise AuthorityError("cloud return has no local terminal status")
    commits = result.get("outcome_commits")
    if not isinstance(commits, int) or isinstance(commits, bool) or commits < 0:
        raise AuthorityError("cloud return commit count is malformed")
    tip = result.get("outcome_tip")
    if not isinstance(tip, str) or not re.fullmatch(r"[0-9a-f]{40}", tip):
        raise AuthorityError("cloud return outcome tip is malformed")
    if kind == "ship" and commits:
        branch = "refs/heads/fm/{}".format(task)
        branch_head = git(worktree, "rev-parse", "--verify", branch)
        if subprocess.run(["git", "-C", str(worktree), "merge-base", "--is-ancestor", tip, branch_head]).returncode != 0:
            raise AuthorityError("cloud return commit is not reachable from the required task branch")
        if git(worktree, "symbolic-ref", "--quiet", "HEAD") != branch:
            raise AuthorityError("cloud return task branch is not checked out")
    uncommitted = result.get("outcome_uncommitted_changes")
    if not isinstance(uncommitted, bool):
        raise AuthorityError("cloud return working-tree disposition is malformed")
    if uncommitted:
        scratch_destinations = {
            "scratch.patch": home / "data" / task / "cloud-scratch.patch",
            "scratch-untracked.tar": home / "data" / task / "cloud-scratch-untracked.tar",
        }
        declared = [name for name in scratch_destinations if name in artifacts]
        if not declared:
            raise AuthorityError("cloud return reports uncommitted work without retained scratch custody")
        for name in declared:
            descriptor = artifacts[name]
            path = scratch_destinations[name]
            if not isinstance(descriptor, dict):
                raise AuthorityError("cloud return scratch custody descriptor is malformed")
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 128 * 1024 * 1024:
                raise AuthorityError("cloud return scratch custody is absent, redirected, or oversized")
            body = path.read_bytes()
            if (
                descriptor.get("bytes") != len(body)
                or descriptor.get("sha256") != hashlib.sha256(body).hexdigest()
            ):
                raise AuthorityError("cloud return scratch custody differs from the manifest")
    return canonical({
        "result_digest": supplied,
        "bundle_sha256": result["outcome_sha256"],
        "manifest_sha256": result["return_manifest_sha256"],
        "outcome_tip": tip,
        "outcome_commits": commits,
        "terminal": status_lines[-1],
    })


def landing_evidence(worktree, repository_generation):
    # Only the canonical origin remote proves landing; a scratch or fork
    # remote-tracking ref must not count, and an unpushed local default
    # branch is not landed work. The landed head must also descend from the
    # assignment's exact starting repository generation, so a receipt can
    # never be minted from an unrelated worktree lineage.
    head = git(worktree, "rev-parse", "HEAD")
    lineage = subprocess.run(
        ["git", "-C", str(worktree), "merge-base", "--is-ancestor", repository_generation, head]
    )
    if lineage.returncode != 0:
        raise AuthorityError("landing authority head does not descend from the assignment repository generation")
    git(
        worktree, "fetch", "--quiet", "--no-tags", "--prune", "origin",
        "+refs/heads/*:refs/remotes/origin/*",
    )
    refs = git(worktree, "for-each-ref", "--format=%(refname)", "refs/remotes/origin").splitlines()
    for ref in refs:
        if ref == "refs/remotes/origin/HEAD":
            continue
        result = subprocess.run(["git", "-C", str(worktree), "merge-base", "--is-ancestor", head, ref])
        if result.returncode == 0:
            return "{}\0{}\0{}".format(head, ref, repository_generation).encode()
    raise AuthorityError("landing authority did not prove committed work reachable from the origin remote")


def secondmate_monitor_state(home, task):
    """The compartment monitor's durable state, or a refusal. Its existence is
    itself evidence: the monitor wrote it while verifying the outbox chain."""
    path = home / "state" / (task + ".cloud-secondmate-state.json")
    if path.is_symlink() or not path.is_file() or path.stat().st_size > SECONDMATE_MAX_STATE_BYTES:
        raise AuthorityError("secondmate authority has no durable monitor state")
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise AuthorityError("secondmate authority has no durable monitor state")
    if not isinstance(state, dict):
        raise AuthorityError("secondmate authority has no durable monitor state")
    return state


def secondmate_chain_canonical(value):
    """The monitor's canonical form, byte for byte (ensure_ascii=False)."""
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()


def secondmate_chain_extent(worker):
    """The verified chain tip, read ONLY from the controller-owned worker record.

    A hash chain proves nothing without a trustworthy anchor. This one is
    anchored at one end by a public genesis constant, and at the other by its
    verified tip - so wherever the tip comes from IS the security boundary.
    Two earlier versions of this function read the tip out of
    state/<task>.cloud-secondmate-state.json: the same attacker-writable file,
    in the same directory as the mailbox, that the check exists to police. An
    attacker recomputes SHA-256 exactly as the monitor does, writes a matching
    tip, and a wholly fabricated chain verifies. The monitor's equivalent check
    is sound because the monitor is the live writer comparing against its own
    prior persisted state; for this tool - which by its own endpoint receipt
    runs only after the monitor is dead and the file is unowned - it was
    vacuous.

    The tip therefore comes from the controller document: fenced, lock-guarded,
    written only by `fm-worker-lifecycle.sh compartment-chain-tip`, and handed
    to this tool inside the same durable worker record that already carries the
    bindings and the role. That is exactly the provenance that closed the
    role/kind escalation.

    ABSENT IS REFUSED, never inferred. A compartment whose monitor has not yet
    recorded tips cannot prove landing through the ordinary authority at all;
    its sanctioned exit is `surrender`. Proving landing from state the attacker
    controls is not an option, so when there is no controller-owned tip the
    honest answer is to refuse."""
    tip = worker.get("verified_chain_tip")
    if not isinstance(tip, dict):
        raise AuthorityError(
            "secondmate landing authority: the controller-owned worker record carries no verified "
            "chain tip; landing cannot be proved from monitor-local state, so this compartment "
            "exits through surrender until its monitor records tips with compartment-chain-tip")
    sequence = tip.get("sequence")
    chain_digest = tip.get("chain_digest")
    if (
        isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 1
        or not isinstance(chain_digest, str) or not SECONDMATE_HEX64.fullmatch(chain_digest)
    ):
        raise AuthorityError(
            "secondmate landing authority: the controller-owned verified chain tip is malformed")
    return sequence, chain_digest


def secondmate_verified_chain(mailbox, tip_sequence, tip_digest):
    """Re-derive the collected outbox chain BY CONTENT and return its verified
    messages in order.

    Filenames prove nothing: they are attacker-writable, and an earlier
    version counted well-named files without ever reading them, so two junk
    blobs named 00000001-<hex>.json / 00000002-<hex>.json satisfied a
    cardinality check while declaring no bundles at all. The chain is
    content-addressed and hash-chained precisely so it can be re-derived, and
    this mirrors the monitor's own verify_mailbox: each entry's name digest
    must equal the SHA-256 of its canonical unsigned body, its sequence field
    must match its name, each chain_digest must extend the previous, and the
    recomputed chain must reproduce the CONTROLLER-OWNED verified tip.

    That last clause is load-bearing and its anchor is the whole point. The
    chain's genesis is a public constant, so the tip is the only thing tying a
    chain to THIS compartment; while the tip was read from monitor-local
    state, an attacker could mint a fresh self-consistent chain and a matching
    tip, and everything verified. The tip now comes from the controller
    document (secondmate_chain_extent).

    Recorded limitation: the content address binds the PARSED OBJECT, not the
    file bytes - the body is re-canonicalized after json.loads - so trailing
    newlines, pretty-printing, and raw key reordering are tolerated. Any
    SEMANTIC change moves the digest, so this buys an attacker nothing, but it
    is a real difference from byte-for-byte comparison and is stated here
    rather than left for the next reader to discover."""
    by_sequence = {}
    for entry in sorted(mailbox.iterdir()):
        if entry.is_symlink() or not entry.is_file():
            continue
        match = SECONDMATE_MESSAGE_NAME.fullmatch(entry.name)
        if not match:
            continue
        sequence = int(match.group(1))
        if sequence in by_sequence:
            raise AuthorityError(
                "secondmate landing authority: duplicate outbox sequence {:08d}".format(sequence))
        by_sequence[sequence] = (match.group(2), entry)
    total = len(by_sequence)
    required = tip_sequence
    if total < required:
        raise AuthorityError(
            "secondmate landing authority: the collected mailbox holds {} outbox entries but the "
            "controller-owned tip records {} (a rewound or truncated outbox)".format(
                total, required))
    if sorted(by_sequence) != list(range(1, total + 1)):
        raise AuthorityError(
            "secondmate landing authority: collected outbox sequences are not exactly 1..{} "
            "(a dropped or reordered entry)".format(total))
    chain = SECONDMATE_GENESIS_CHAIN_DIGEST
    verified = []
    for sequence in range(1, total + 1):
        content_digest, entry = by_sequence[sequence]
        if entry.stat().st_size > SECONDMATE_MAX_MESSAGE_BYTES:
            raise AuthorityError(
                "secondmate landing authority found an oversized outbox entry: {}".format(entry.name))
        try:
            message = json.loads(entry.read_bytes().decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            raise AuthorityError(
                "secondmate landing authority cannot read outbox entry {}".format(entry.name))
        if not isinstance(message, dict):
            raise AuthorityError(
                "secondmate landing authority: outbox entry {:08d} is not a JSON object".format(sequence))
        unsigned = dict(message)
        claimed_content = unsigned.pop("content_sha256", None)
        claimed_chain = unsigned.pop("chain_digest", None)
        if hashlib.sha256(secondmate_chain_canonical(unsigned)).hexdigest() != content_digest:
            raise AuthorityError(
                "secondmate landing authority: outbox entry {:08d} content differs from its content "
                "address (tampered or substituted)".format(sequence))
        if claimed_content != content_digest or message.get("sequence") != sequence:
            raise AuthorityError(
                "secondmate landing authority: outbox entry {:08d} does not bind its own name".format(
                    sequence))
        expected_chain = hashlib.sha256((chain + content_digest).encode()).hexdigest()
        if claimed_chain != expected_chain:
            raise AuthorityError(
                "secondmate landing authority: outbox entry {:08d} chain_digest does not extend the "
                "previous entry".format(sequence))
        chain = expected_chain
        verified.append((sequence, message))
    if verified[tip_sequence - 1][1].get("chain_digest") != tip_digest:
        raise AuthorityError(
            "secondmate landing authority: the recomputed chain at sequence {} does not reproduce "
            "the controller-owned verified tip (a re-genesis or substitution)".format(tip_sequence))
    return verified


def secondmate_bundle_ledger(home, task, worker):
    """Declared and collected outbox bundles against the monitor's durable
    landed record, over a chain re-derived BY CONTENT.

    Two earlier versions of this function were forgeable, and both failures
    had the same shape: they trusted something the attacker can write. The
    first trusted mere enumeration, so an emptied mailbox read as "provably
    none". The second added a cardinality check against the durable monitor
    state - but that state lives in the same state/ directory as the mailbox,
    inside the attacker's write set, so counting well-named files proved
    nothing.

    What is NOT in the attacker's gift is the chain's own arithmetic: every
    entry is content-addressed and hash-chained, so a forged mailbox must
    reproduce SHA-256 to be accepted. This function therefore verifies the
    chain rather than counting it, and refuses outright when the durable state
    is malformed instead of coercing it to a permissive zero.

    Within a verified chain, enumeration stays deliberately one-sided:
    declarations come from VERIFIED leg summaries, and collected bundle files
    are read by name as well, so an unenumerated bundle can only ADD to what
    must be proven landed, never subtract."""
    mailbox = home / "state" / (task + ".cloud-mailbox")
    # lexists, not exists: a DANGLING symlink named .chain-break is still a
    # marker in the mailbox, and exists() follows it into nothing, which
    # silently bypassed the freeze a real marker triggers.
    if os.path.lexists(str(mailbox / ".chain-break")):
        raise AuthorityError(
            "secondmate landing authority is frozen by a recorded outbox chain break")
    state = secondmate_monitor_state(home, task)
    landed = {entry for entry in state.get("landed_bundles") or [] if isinstance(entry, str)}
    kept = sorted(entry for entry in state.get("kept_bundles") or [] if isinstance(entry, str))
    tip_sequence, tip_digest = secondmate_chain_extent(worker)
    # A symlinked mailbox is not the monitor's mailbox: is_dir() follows the
    # link, so a link to an empty directory read as a legitimately empty chain.
    if mailbox.is_symlink() or not mailbox.is_dir():
        raise AuthorityError(
            "secondmate landing authority: the controller-owned tip records {} outbox "
            "entries but the mailbox is absent or redirected".format(tip_sequence))
    verified = secondmate_verified_chain(mailbox, tip_sequence, tip_digest)
    declared = set()
    for _sequence, message in verified:
        if message.get("kind") != SECONDMATE_LEG_SUMMARY_KIND:
            continue
        for declaration in message.get("bundles") or []:
            if isinstance(declaration, dict) and isinstance(declaration.get("sha256"), str):
                declared.add(declaration["sha256"])
    collected = set()
    for entry in sorted(mailbox.iterdir()):
        if entry.is_symlink() or not entry.is_file():
            continue
        bundle = SECONDMATE_BUNDLE_NAME.fullmatch(entry.name)
        if bundle:
            collected.add(bundle.group(1))
    return state, landed, kept, declared, collected


def secondmate_bundle_file(home, task, digest):
    """The collected bundle file for one digest, or None. Named by digest, so
    the lookup cannot be redirected by an attacker choosing a sequence."""
    mailbox = home / "state" / (task + ".cloud-mailbox")
    if mailbox.is_symlink() or not mailbox.is_dir():
        return None
    for entry in sorted(mailbox.iterdir()):
        if entry.is_symlink() or not entry.is_file():
            continue
        match = SECONDMATE_BUNDLE_NAME.fullmatch(entry.name)
        if match and match.group(1) == digest:
            return entry
    return None


def secondmate_report_evidence(home, task):
    """Session closeout: terminal status file, chained close ack, completion.md."""
    status_path = home / "state" / (task + ".cloud-secondmate-status")
    if status_path.is_symlink() or not status_path.is_file():
        raise AuthorityError("secondmate report authority lacks the terminal session status")
    try:
        terminal = status_path.read_text(encoding="utf-8").strip()
    except (OSError, ValueError):
        raise AuthorityError("secondmate report authority lacks the terminal session status")
    ack = SECONDMATE_TERMINAL_ACKS.get(terminal)
    if ack is None:
        raise AuthorityError(
            "secondmate report authority terminal status is unrecognized: {!r}".format(terminal))
    summary = secondmate_monitor_state(home, task).get("last_summary")
    legs = (summary or {}).get("legs_completed") if isinstance(summary, dict) else None
    if (
        not isinstance(summary, dict)
        or summary.get("reason") != ack
        or isinstance(legs, bool)
        or not isinstance(legs, int)
        or legs < 1
    ):
        raise AuthorityError(
            "secondmate report authority lacks the chained close ack for terminal status {!r}".format(terminal))
    content = report_evidence(home, task)
    # The shared report_evidence stays VERBATIM (design B.7, and it serves the
    # ordinary lane too), so this is an ADDITIONAL compartment-only check on
    # top of it. The shared one is text.find() plus monotonic position, which
    # accepts headings inside a fenced code block, mid-sentence in prose,
    # concatenated with no whitespace, or as a body-less skeleton. For a
    # compartment the closeout report is the only human-readable account of a
    # long-lived session, so require each heading to actually open a section:
    # at the start of its own line, outside any fence, with content under it.
    secondmate_report_sections(content)
    return "{}\0{}\0{}\0".format(terminal, ack, legs).encode() + content


def secondmate_report_sections(content):
    """Every contract heading opens a real section, in order, outside fences.

    Recorded limitation: "carries content" is any non-empty text, so a single
    "." under each heading still passes. This is cosmetic - it cannot hide
    unlanded work or a missing closeout - and closing it would mean inventing
    a prose-quality bar the ordinary lane does not have either."""
    fenced = False
    seen = []
    bodies = {}
    current = None
    for raw in content.decode("utf-8").splitlines():
        line = raw.strip()
        if line.startswith("```") or line.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        if raw.lstrip().startswith("## ") and raw.lstrip() in REQUIRED_HEADINGS:
            current = raw.lstrip()
            seen.append(current)
            bodies.setdefault(current, "")
            continue
        if current is not None and line:
            bodies[current] += line
    if seen != list(REQUIRED_HEADINGS):
        raise AuthorityError(
            "secondmate report authority: the closeout report does not open the exact ordered "
            "contract sections outside code fences")
    empty = [heading for heading in REQUIRED_HEADINGS if not bodies.get(heading)]
    if empty:
        raise AuthorityError(
            "secondmate report authority: closeout report section(s) {} carry no content".format(
                ", ".join(empty)))


def secondmate_prove_landed(home, task, worker, worktree, head):
    """Prove every declared or collected bundle actually landed in the home.

    Reachability, not assertion: the collected bundle names its own tip commit,
    and that tip must be an ancestor of the home worktree's HEAD. The monitor's
    landed_bundles is advisory - it is attacker-writable, and trusting it let a
    single file write mint a landing proof over commits that were never in the
    home. A declared bundle whose file is gone cannot be proven and refuses."""
    _state, _claimed, _kept, declared, collected = secondmate_bundle_ledger(home, task, worker)
    proven = {}
    for digest in sorted(declared | collected):
        local = secondmate_bundle_file(home, task, digest)
        if local is None:
            raise AuthorityError(
                "secondmate landing authority cannot prove bundle {} landed: its collected file "
                "is absent, so nothing names the commits it carried".format(digest))
        body = local.read_bytes()
        if len(body) > SECONDMATE_MAX_BUNDLE_BYTES or hashlib.sha256(body).hexdigest() != digest:
            raise AuthorityError(
                "secondmate landing authority: collected bundle {} differs from its digest".format(digest))
        heads = subprocess.run(
            ["git", "-C", str(worktree), "bundle", "list-heads", str(local)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        tips = [
            line.split()[0] for line in heads.stdout.decode("utf-8", errors="replace").splitlines()
            if line.split()
        ]
        if heads.returncode != 0 or not tips:
            raise AuthorityError(
                "secondmate landing authority cannot read the heads of collected bundle {}".format(digest))
        for tip_commit in tips:
            reachable = subprocess.run(
                ["git", "-C", str(worktree), "merge-base", "--is-ancestor", tip_commit, head],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if reachable.returncode != 0:
                raise AuthorityError(
                    "secondmate landing authority found unlanded outbox bundles: {} (its commit {} "
                    "is not reachable from the home worktree head)".format(digest, tip_commit[:12]))
        proven[digest] = sorted(tips)
    return proven


def secondmate_landing_evidence(home, task, worker, worktree, repository_generation):
    """Every chained outbox bundle PROVABLY landed into the local home
    worktree, or provably none: the durable monitor state keeps nothing, every
    declared or collected bundle's tip commit is reachable from the home
    worktree's HEAD, and that HEAD descends from the assignment's exact
    starting repository generation.

    The reachability check is what makes this a proof. `landed_bundles` in the
    durable monitor state is ADVISORY only: it is one more attacker-writable
    field, and while this receipt trusted it, naming a digest there minted a
    landing proof for commits that were nowhere in the home - a single file
    write, no CLI and no hashing, falsifying the receipt's own sentence.

    That last clause is the same lineage tether the ordinary lane applies
    (landing_evidence): without it the compartment receipt was bound only to
    LOCAL files, so a home whose head belongs to an entirely unrelated
    lineage still minted a landing proof. The controller owns
    repository_generation in the worker record, so it cannot be edited from
    the task metadata the way `kind` can."""
    state, claimed_landed, kept, declared, collected = secondmate_bundle_ledger(home, task, worker)
    if kept:
        raise AuthorityError(
            "secondmate landing authority found bundles kept unlanded: {}".format(",".join(kept)))
    head = git(worktree, "rev-parse", "HEAD")
    # LANDING IS PROVEN, NOT CLAIMED. landed_bundles is advisory: it lives in
    # the same attacker-writable durable file as everything else the monitor
    # records, so simply naming a digest there used to satisfy this receipt
    # while the bundle's commits were nowhere in the home. The material needed
    # to check is already on disk - the collected bundle names its own tip
    # commit - so each declared or collected bundle counts as landed only when
    # that tip is provably reachable from the home worktree's HEAD.
    proven = secondmate_prove_landed(home, task, worker, worktree, head)
    lineage = subprocess.run(
        ["git", "-C", str(worktree), "merge-base", "--is-ancestor", repository_generation, head],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if lineage.returncode != 0:
        raise AuthorityError(
            "secondmate landing authority home head does not descend from the assignment "
            "repository generation")
    tip = worker.get("verified_chain_tip") or {}
    return canonical({
        # The controller-owned tip, not the monitor-local counter: the evidence
        # blob should name the anchor the proof actually rests on.
        "chain_tip_sequence": tip.get("sequence"),
        "chain_tip_digest": tip.get("chain_digest"),
        "declared": sorted(declared),
        # What was PROVEN reachable in the home, with the commits that prove
        # it - not what the monitor-local file claimed.
        "landed": {digest: proven[digest] for digest in sorted(proven)},
        "landed_claimed": sorted(claimed_landed),
        "head": head,
        "repository_generation": repository_generation,
    })


def secondmate_worktree_evidence(home, task, values, worker):
    """Home quiesced: the exact secondmate home worktree root with nothing
    left in it - no tracked modifications, no untracked never-added work, and
    no unlanded outbox bundles.

    Untracked files count, exactly as they do in the ordinary lane: a release
    receipt answers "is anything left here", not the monitor's narrower "can I
    fast-forward into this", and the repo's own .gitignore already excludes
    the home's runtime state (/state/, /data/, /projects/), which
    --untracked-files=all never lists anyway. Children are deliberately NOT
    consulted: command_release refuses live children under the controller
    lock, so this receipt stays advisory for them."""
    worktree = Path(exactly(values, "worktree")).resolve()
    if worktree.is_symlink() or not worktree.is_dir() or Path(git(worktree, "rev-parse", "--show-toplevel")).resolve() != worktree:
        raise AuthorityError("secondmate home worktree authority is not the exact repository root")
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all"):
        raise AuthorityError(
            "secondmate home worktree authority is not quiesced: uncommitted or untracked work remains")
    _state, _claimed, kept, _declared, _collected = secondmate_bundle_ledger(home, task, worker)
    if kept:
        raise AuthorityError(
            "secondmate home worktree authority is not quiesced: unlanded outbox bundles remain")
    # Same proof as the landing receipt, not the monitor's claim: quiesced
    # means nothing is left unlanded, and that is decided by reachability.
    try:
        secondmate_prove_landed(home, task, worker, worktree, git(worktree, "rev-parse", "HEAD"))
    except AuthorityError as exc:
        raise AuthorityError(
            "secondmate home worktree authority is not quiesced: unlanded outbox bundles remain "
            "({})".format(exc))
    common = Path(git(worktree, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = (worktree / common).resolve()
    return "{}\0{}\0{}".format(worktree, common.resolve(), git(worktree, "rev-parse", "HEAD")).encode(), worktree


def account_evidence(values, task, home, worker=None):
    account_home = exactly(values, "account_home")
    if not Path(account_home).resolve().is_dir():
        raise AuthorityError("account authority directory is unavailable")
    account_tasks = values.get("account_task", [])
    if account_tasks and account_tasks != [task]:
        raise AuthorityError("account authority task identity differs")
    account_task = task
    placements = values.get("placement", [])
    if placements:
        if placements != ["azure"]:
            raise AuthorityError("ordinary account authority placement is ambiguous")
        return azure_account_evidence(values, task, worker)
    helper = ROOT / "bin" / "fm-account-directory.sh"
    if not helper.is_file():
        raise AuthorityError("ordinary account authority helper is unavailable")
    vendor = "claude" if "claude" in Path(account_home).parts else "codex" if "codex" in Path(account_home).parts else ""
    if not vendor:
        raise AuthorityError("ordinary account authority vendor is ambiguous")
    # The helper's real library API: account_root prints the accounts root,
    # valid_account_home gates <vendor-dir>/<name> shape, and
    # fm_account_real_directory is a non-symlink directory predicate.
    # Positionals are cleared before sourcing so the helper's command dispatch
    # never sees them.
    script = (
        'helper="$1"; vendor="$2"; account="$3"; set --; . "$helper"; '
        'root=$(account_root) || exit 1; vendor_dir="$root/$vendor"; '
        'fm_account_real_directory "$vendor_dir" || exit 1; '
        'valid_account_home "$vendor_dir" "$account" || exit 1; '
        'fm_account_real_directory "$account" || exit 1; '
        'cd "$account" && pwd -P'
    )
    result = subprocess.run(
        ["bash", "-c", script, "_", str(ROOT / "bin" / "fm-account-directory.sh"), vendor, account_home],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, "FM_HOME": str(home), "FM_ROOT": str(home)},
    )
    if result.returncode != 0:
        raise AuthorityError("ordinary account authority did not prove the exact task/account home")
    account_real = result.stdout.decode().strip()
    if Path(account_real).resolve() != Path(account_home).resolve():
        raise AuthorityError("ordinary account authority canonical home differs")
    return "{}\0{}\0ordinary-account-owner".format(Path(account_home).resolve(), account_task).encode()


def load_pi_projection():
    try:
        spec = importlib.util.spec_from_file_location(
            "fm_pi_account_home", PI_ACCOUNT_HOME_TOOL)
        if spec is None or spec.loader is None:
            raise AuthorityError(
                "ordinary Azure account authority projection helper is unavailable")
        projection = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(projection)
        return projection
    except AuthorityError:
        raise
    except Exception as exc:  # noqa: BLE001 - any import failure refuses
        raise AuthorityError(
            "ordinary Azure account authority projection helper failed: {}".format(
                type(exc).__name__))


def open_private_account_directory(path):
    """Open an absolute directory one no-follow component at a time."""
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        descriptor = os.open("/", flags)
    except OSError as exc:
        raise AuthorityError(
            "ordinary Azure account authority lease path is unreadable: {}".format(
                type(exc).__name__))
    identities = []
    try:
        components = path.parts[1:]
        for index, component in enumerate(components):
            if component in ("", ".", ".."):
                raise AuthorityError(
                    "ordinary Azure account authority lease path is malformed")
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            info = os.fstat(descriptor)
            if not stat.S_ISDIR(info.st_mode):
                raise AuthorityError(
                    "ordinary Azure account authority lease path is not a directory")
            if index == len(components) - 1 and info.st_mode & (
                    stat.S_IWGRP | stat.S_IWOTH):
                raise AuthorityError(
                    "ordinary Azure account authority lease directory is not owner-private")
            if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH) and not (
                    info.st_mode & stat.S_ISVTX):
                raise AuthorityError(
                    "ordinary Azure account authority lease path is writable by others")
            identities.append((info.st_dev, info.st_ino))
        leaf = os.fstat(descriptor)
        if leaf.st_uid != os.geteuid() or leaf.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise AuthorityError(
                "ordinary Azure account authority lease directory is not owner-private")
        return descriptor, identities
    except AuthorityError:
        os.close(descriptor)
        raise
    except OSError as exc:
        os.close(descriptor)
        raise AuthorityError(
            "ordinary Azure account authority lease path is unsafe: {}".format(
                type(exc).__name__))


def read_private_pi_pool(path, max_bytes, max_profiles):
    """Read auth.json through one pinned descriptor and recheck its pathname."""
    directory, chain = open_private_account_directory(path)
    credential = None
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        credential = os.open("auth.json", flags, dir_fd=directory)
        before = os.fstat(credential)
        if not stat.S_ISREG(before.st_mode):
            raise AuthorityError(
                "ordinary Azure account authority lease credential is not regular")
        if before.st_uid != os.geteuid() or before.st_mode & (
                stat.S_IRWXG | stat.S_IRWXO):
            raise AuthorityError(
                "ordinary Azure account authority lease credential is not owner-private")
        if before.st_size > max_bytes:
            raise AuthorityError(
                "ordinary Azure account authority lease credential exceeds its byte bound")
        chunks = []
        remaining = max_bytes + 1
        while remaining:
            chunk = os.read(credential, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        body = b"".join(chunks)
        if len(body) > max_bytes:
            raise AuthorityError(
                "ordinary Azure account authority lease credential exceeds its byte bound")
        after = os.fstat(credential)
        identity = lambda value: (
            value.st_dev, value.st_ino, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns,
        )
        current = os.stat("auth.json", dir_fd=directory, follow_symlinks=False)
        if identity(before) != identity(after) or before.st_size != len(body) or (
                current.st_dev, current.st_ino) != (before.st_dev, before.st_ino):
            raise AuthorityError(
                "ordinary Azure account authority lease credential changed during proof")
        current_directory, current_chain = open_private_account_directory(path)
        os.close(current_directory)
        if current_chain != chain:
            raise AuthorityError(
                "ordinary Azure account authority lease path changed during proof")
    except AuthorityError:
        raise
    except OSError as exc:
        raise AuthorityError(
            "ordinary Azure account authority lease credential is unreadable: {}".format(
                type(exc).__name__))
    finally:
        if credential is not None:
            os.close(credential)
        os.close(directory)
    try:
        pool = json.loads(body.decode("utf-8"))
    except (UnicodeError, ValueError) as exc:
        raise AuthorityError(
            "ordinary Azure account authority lease credential is malformed: {}".format(
                type(exc).__name__))
    if not isinstance(pool, dict) or len(pool) > max_profiles:
        raise AuthorityError(
            "ordinary Azure account authority lease credential object is malformed")
    return pool


def azure_account_evidence(values, task, worker):
    """Prove the exact controller-selected Pi account lease for cloud work.

    `account_home` is deliberately the multi-profile Pi pool and has no
    claude/codex path component. The controller-selected, single-profile home
    is recorded separately and its credential content is what minted the
    controller-owned account binding.
    """
    leased_home = Path(exactly(values, "worker_account_home"))
    if not leased_home.is_absolute():
        raise AuthorityError("ordinary Azure account authority lease directory is malformed")
    profile = exactly(values, "worker_account_profile")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}", profile):
        raise AuthorityError("ordinary Azure account authority profile is malformed")
    bindings = worker.get("bindings") if isinstance(worker, dict) else None
    expected_binding = bindings.get("account_binding") if isinstance(bindings, dict) else None
    if not isinstance(expected_binding, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_binding):
        raise AuthorityError("ordinary Azure account authority binding is unavailable")
    lease = worker.get("account_lease") if isinstance(worker, dict) else None
    expected_home = lease.get("account_home") if isinstance(lease, dict) else None
    expected_profile = lease.get("account_profile") if isinstance(lease, dict) else None
    if not isinstance(expected_home, str) or not isinstance(expected_profile, str):
        raise AuthorityError("ordinary Azure account authority lease identity is unavailable")
    if str(leased_home) != expected_home or profile != expected_profile:
        raise AuthorityError("ordinary Azure account authority lease identity differs")
    projection = load_pi_projection()
    pool = read_private_pi_pool(
        leased_home, projection.MAX_SOURCE_BYTES, projection.MAX_PROFILES)
    if len(pool) != 1:
        raise AuthorityError("ordinary Azure account authority lease is not single-profile")
    credential = next(iter(pool.values()))
    if projection.entry_faults(credential):
        raise AuthorityError("ordinary Azure account authority lease credential is malformed")
    upstream = projection.account_digest(credential)
    if upstream == "none":
        raise AuthorityError("ordinary Azure account authority lease has no upstream identity")
    observed_binding = digest({"provider": "pi", "upstream_account": upstream})
    if observed_binding != expected_binding:
        raise AuthorityError("ordinary Azure account authority lease binding differs")
    return canonical({
        "account_binding": expected_binding,
        "account_home": expected_home,
        "account_profile": profile,
        "account_task": task,
        "owner": "ordinary-account-owner",
    })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--task-generation", required=True)
    parser.add_argument("--assignment-generation", required=True)
    parser.add_argument("--worker-state", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}", args.task):
        raise AuthorityError("task identity is malformed")
    home = Path(args.home).resolve()
    metadata = home / "state" / (args.task + ".meta")
    if metadata.is_symlink() or not metadata.is_file():
        raise AuthorityError("ordinary task metadata authority is absent")
    values = meta(metadata)
    generation = exactly(values, "generation_id")
    if generation != args.task_generation:
        raise AuthorityError("ordinary task generation differs")
    worker = json.loads(Path(args.worker_state).read_text(encoding="utf-8"))
    if worker["assignment_generation"] != args.assignment_generation:
        raise AuthorityError("worker assignment generation differs")
    kind_entries = values.get("kind", [])
    if len(kind_entries) > 1:
        raise AuthorityError("task metadata kind identity is not exact")
    # WHICH evidence semantics apply is a release-safety decision, so it may
    # not rest on the task metadata alone: `kind` is a local, operator-writable
    # line, while `role` is minted by the controller into the worker record and
    # travels here inside the same durable document the bindings come from.
    # Flipping one meta line must never move an ordinary author worker onto the
    # compartment lane, where the ordinary landing proof (commits reachable
    # from origin) is replaced by compartment evidence and unlanded work can be
    # released. Both directions refuse, fail closed, before any evidence runs.
    meta_kind = kind_entries[0] if kind_entries else ""
    worker_role = worker.get("role", "author")
    if meta_kind == "secondmate" and worker_role != "secondmate":
        raise AuthorityError(
            "task metadata claims a secondmate compartment but the controller-owned worker "
            "role is {!r}; compartment evidence is refused".format(worker_role))
    if worker_role == "secondmate" and meta_kind != "secondmate":
        raise AuthorityError(
            "the controller-owned worker role is secondmate but the task metadata kind is "
            "{!r}; ordinary evidence is refused for a compartment".format(meta_kind))
    if worker_role == "secondmate":
        # The secondmate compartment evidence mode (design B.7): same bundle,
        # same five receipt names, compartment semantics. The bundle still
        # verifies through the lifecycle's UNMODIFIED release_receipt and
        # verify_release_against_worker.
        worktree_info, home_worktree = secondmate_worktree_evidence(home, args.task, values, worker)
        report_authority = lambda: secondmate_report_evidence(home, args.task)
        landing_authority = lambda: secondmate_landing_evidence(
            home, args.task, worker, home_worktree, worker["bindings"]["repository_generation"])
    else:
        worktree_info, worktree = worktree_evidence(args.task, values)
        ordinary_kind = meta_kind if meta_kind in ("ship", "scout") else "ship"
        report_authority = lambda: report_evidence(home, args.task, ordinary_kind)
        result_path = home / "state" / (args.task + ".worker-result.json")
        has_authorized_return = False
        if values.get("placement", []) == ["azure"] and result_path.is_file() and not result_path.is_symlink():
            try:
                has_authorized_return = json.loads(
                    result_path.read_text(encoding="utf-8")
                ).get("return_present") is True
            except (OSError, ValueError, AttributeError):
                has_authorized_return = False
        if has_authorized_return:
            landing_authority = lambda: cloud_return_evidence(
                home, args.task, generation, args.assignment_generation,
                ordinary_kind, worktree, worker["bindings"]["repository_generation"],
            )
        else:
            landing_authority = lambda: landing_evidence(
                worktree, worker["bindings"]["repository_generation"])
    authorities = {
        "endpoint": receipt("endpoint", args.task, generation, args.assignment_generation, endpoint_evidence(home, args.task, values)),
        "report": receipt("report", args.task, generation, args.assignment_generation, report_authority()),
        "landing": receipt("landing", args.task, generation, args.assignment_generation, landing_authority()),
        "account": receipt(
            "account", args.task, generation, args.assignment_generation,
            account_evidence(values, args.task, home, worker),
        ),
        "worktree": receipt("worktree", args.task, generation, args.assignment_generation, worktree_info),
    }
    proof = {
        "schema": RELEASE_SCHEMA,
        "home_binding": worker["bindings"]["home_binding"],
        "task": args.task,
        "task_generation": generation,
        "assignment_generation": args.assignment_generation,
        "account_binding": worker["bindings"]["account_binding"],
        "worktree_binding": worker["bindings"]["worktree_binding"],
        "repository_binding": worker["bindings"]["repository_binding"],
        "repository_generation": worker["bindings"]["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"],
        "resources": worker["resources"],
        "authorities": authorities,
    }
    proof["proof_digest"] = digest(proof)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    os.chmod(output, 0o600)


if __name__ == "__main__":
    try:
        main()
    except (AuthorityError, OSError, KeyError, json.JSONDecodeError) as exc:
        print("WORKER AUTHORITY REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
