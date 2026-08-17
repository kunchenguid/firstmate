#!/usr/bin/env python3
"""Verify Firstmate progressive-disclosure preservation and reachability."""

from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MANIFEST_PATH = Path("docs/verification/prompt-disclosure-manifest.json")
LINEAGE_PATH = Path("docs/verification/prompt-lineage.json")
EXPECTED_UPSTREAM_COMMIT = "9823ff899c58319e5a09846b18f2958018598b38"
EXPECTED_UPSTREAM_ARTIFACT = "docs/verification/prompt-preservation/upstream/AGENTS.md.txt"
EXPECTED_UPSTREAM_ARTIFACT_SHA256 = "4b4aa612a48ff1642558748080d353f12f49c9931da1bdaa52f5c63d384a750c"
EXPECTED_LIVE_AUTHORITY_PATHS = (
    ".agents/prompt-roles/secondmate.md",
    ".agents/skills/afk/SKILL.md",
    ".agents/skills/ahoy/SKILL.md",
    ".agents/skills/ask-user-authority/SKILL.md",
    ".agents/skills/bearings/SKILL.md",
    ".agents/skills/bootstrap-diagnostics/SKILL.md",
    ".agents/skills/decision-hold-lifecycle/SKILL.md",
    ".agents/skills/diagnostic-reasoning/SKILL.md",
    ".agents/skills/firstmate-codexapp/SKILL.md",
    ".agents/skills/firstmate-coding-guidelines/SKILL.md",
    ".agents/skills/firstmate-orca/SKILL.md",
    ".agents/skills/fmx-respond/SKILL.md",
    ".agents/skills/harness-adapters/SKILL.md",
    ".agents/skills/process-event-sources/SKILL.md",
    ".agents/skills/project-management/SKILL.md",
    ".agents/skills/quota-array-dispatch/SKILL.md",
    ".agents/skills/secondmate-provisioning/SKILL.md",
    ".agents/skills/stow/SKILL.md",
    ".agents/skills/stuck-crewmate-recovery/SKILL.md",
    ".agents/skills/updatefirstmate/SKILL.md",
    "AGENTS.md",
    "FIRSTMATE_BACKLOG.md",
    "FIRSTMATE_BRIEFING.md",
    "FIRSTMATE_DISPATCH.md",
    "FIRSTMATE_OPERATIONAL_HOME.md",
    "FIRSTMATE_PROJECT_KNOWLEDGE.md",
    "FIRSTMATE_RECOVERY.md",
    "FIRSTMATE_TASK_LIFECYCLE.md",
)
EXPECTED_LIVE_AUTHORITY_BINDING_SHA256 = "ad75ab26f28c05cff72b80c9da5de222fab378a96746c9222a150252b39eb28b"
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
LINK_RE = re.compile(r"(?<!!)\[[^]]*]\(([^)]+)\)")


class VerificationError(RuntimeError):
    """A preservation contract was violated."""


def fail(message: str) -> None:
    raise VerificationError(message)


def run(root: Path, *args: str) -> str:
    result = subprocess.run(
        args,
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"command failed ({' '.join(args)}): {detail}")
    return result.stdout


def artifact_bytes(root: Path, relative: str, expected_sha256: str) -> bytes:
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        fail(f"lineage artifact escapes repository: {relative}")
    if not path.is_file():
        fail(f"lineage artifact unavailable: {relative}")
    content = path.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    if digest != expected_sha256:
        fail(f"lineage artifact hash mismatch: {relative}")
    return content


def git_object(root: Path, revision: str, path: str) -> bytes | None:
    result = subprocess.run(["git", "show", f"{revision}:{path}"], cwd=root, capture_output=True)
    return result.stdout if result.returncode == 0 else None


def is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    return subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=root,
        capture_output=True,
    ).returncode == 0


def check_semantic_refresh(root: Path, lineage: dict, evidence: dict) -> None:
    required = ("previous_upstream", "upstream")
    if evidence.get("schema_version") != 1 or not all(isinstance(evidence.get(key), str) for key in required):
        fail("malformed semantic refresh evidence")
    overlay = evidence.get("overlay")
    transformer_hash = evidence.get("transformer_sha256")
    if not isinstance(overlay, str) or not isinstance(transformer_hash, str):
        fail("semantic refresh evidence has no installed-overlay provenance")

    review = lineage.get("semantic_refresh_review")
    reconstruction_overlay = overlay
    expected_current_hash = transformer_hash
    if review is not None:
        if review.get("schema_version") != 1 or not all(
            isinstance(review.get(key), str)
            for key in ("candidate", "reviewer_overlay", "transformer_sha256")
        ):
            fail("malformed semantic refresh review attestation")
        candidate = review["candidate"]
        reviewer = review["reviewer_overlay"]
        candidate_lineage = git_object(root, candidate, LINEAGE_PATH.as_posix())
        candidate_transformer = git_object(root, candidate, "bin/fm-prompt-semantic-refresh.py")
        reviewer_transformer = git_object(root, reviewer, "bin/fm-prompt-semantic-refresh.py")
        producer_transformer = git_object(root, overlay, "bin/fm-prompt-semantic-refresh.py")
        if producer_transformer is not None and is_ancestor(root, candidate, overlay):
            fail("semantic refresh producer is a descendant of the candidate it claims to produce")
        try:
            candidate_record = json.loads(candidate_lineage) if candidate_lineage else None
            recorded_evidence = candidate_record["semantic_refresh"] if candidate_record else None
        except (KeyError, json.JSONDecodeError):
            candidate_record = None
            recorded_evidence = None
        parent_result = subprocess.run(
            ["git", "show", "-s", "--format=%P", candidate],
            cwd=root,
            capture_output=True,
            text=True,
        )
        if parent_result.returncode:
            fail("semantic refresh reviewed candidate graph is unavailable")
        parents = parent_result.stdout.split()
        if recorded_evidence != evidence or parents != [evidence["upstream"]]:
            fail("semantic refresh review does not bind the exact candidate graph and evidence")
        if candidate_record.get("live_authority_sha256") != lineage.get("live_authority_sha256"):
            fail("lineage differs from the fixed live-authority binding")
        if candidate_transformer is None or hashlib.sha256(candidate_transformer).hexdigest() != transformer_hash:
            fail("candidate differs from original semantic refresh implementation binding")
        if not is_ancestor(root, candidate, reviewer) or candidate == reviewer:
            fail("semantic refresh reviewer is not a descendant of the reviewed candidate")
        if reviewer_transformer is None or hashlib.sha256(reviewer_transformer).hexdigest() != review["transformer_sha256"]:
            fail("semantic refresh review implementation differs from reviewer provenance")
        reconstruction_overlay = candidate
        expected_current_hash = review["transformer_sha256"]
    else:
        producer_transformer = git_object(root, overlay, "bin/fm-prompt-semantic-refresh.py")
        if producer_transformer is None or hashlib.sha256(producer_transformer).hexdigest() != transformer_hash:
            fail("semantic refresh implementation differs from installed-overlay provenance")

    current_transformer = root / "bin/fm-prompt-semantic-refresh.py"
    if not current_transformer.is_file() or hashlib.sha256(current_transformer.read_bytes()).hexdigest() != expected_current_hash:
        fail("semantic refresh implementation differs from reviewed provenance")
    with tempfile.TemporaryDirectory(prefix="fm-semantic-verify-") as directory:
        output = Path(directory) / "refresh.json"
        result = subprocess.run(
            [
                sys.executable,
                str(current_transformer),
                "refresh",
                "--previous-upstream", evidence["previous_upstream"],
                "--upstream", evidence["upstream"],
                "--overlay", reconstruction_overlay,
                "--lineage", str(LINEAGE_PATH),
                "--output", str(output),
            ],
            cwd=root,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            fail(f"semantic refresh proof cannot be reconstructed: {result.stderr.strip()}")
        reconstructed = json.loads(output.read_text())
    if reconstructed.get("changes") != evidence.get("changes"):
        fail("semantic refresh owner evidence differs from reconstruction")
    for update in reconstructed.get("updates", []):
        path = root / update["path"]
        content = base64.b64decode(update["content_base64"], validate=True)
        if update["path"] == LINEAGE_PATH.as_posix():
            continue
        if not path.is_file() or path.read_bytes() != content:
            fail(f"semantic refresh output differs from live owner: {update['path']}")


def changed_baseline_lines(root: Path, baseline: str, transformed: str) -> set[int]:
    result = subprocess.run(
        ["git", "diff", "--no-index", "--unified=0", "--", baseline, transformed],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode not in {0, 1}:
        fail(f"could not compare lineage artifacts: {result.stderr.strip()}")
    changed: set[int] = set()
    for line in result.stdout.splitlines():
        match = HUNK_RE.match(line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        changed.update(range(start, start + count))
    return changed


def check_manifest(root: Path, manifest: dict, lineage: dict) -> tuple[list[dict], list[str]]:
    revision = manifest["baseline_git_commit"]
    source_path = manifest["baseline_path"]
    generations = lineage.get("generations", [])
    if lineage.get("schema_version") != 4 or [item.get("generation") for item in generations] != list(range(len(generations))):
        fail("malformed multi-generation lineage")
    phase_one = next((item for item in generations if item.get("kind") == "local-transformation"), None)
    if not phase_one or phase_one.get("manifest") != str(MANIFEST_PATH):
        fail("phase-one generation is not bound to its preservation manifest")
    live_overlay = next((item for item in generations if item.get("kind") == "live-overlay"), None)
    if not live_overlay or live_overlay.get("upstream_binding") != "single-parent":
        fail("live overlay is not bound to its exact upstream parent")
    upstream_base = next((item for item in generations if item.get("kind") == "upstream-base"), None)
    if not upstream_base:
        fail("lineage has no upstream-base generation")
    upstream_artifact = live_overlay.get("upstream_artifact")
    upstream_artifact_sha256 = live_overlay.get("upstream_artifact_sha256")
    if not all(isinstance(value, str) and value for value in (upstream_artifact, upstream_artifact_sha256)):
        fail("live overlay has no self-contained upstream artifact")
    baseline_artifact = upstream_base.get("artifact")
    baseline_artifact_sha256 = upstream_base.get("artifact_sha256")
    transformed_artifact = phase_one.get("source_artifact")
    destination_artifacts = phase_one.get("destination_artifacts")
    artifact_hashes = phase_one.get("artifact_sha256")
    if not all(isinstance(value, str) and value for value in (baseline_artifact, baseline_artifact_sha256, transformed_artifact)):
        fail("lineage has incomplete source artifacts")
    if not isinstance(destination_artifacts, dict) or not isinstance(artifact_hashes, dict):
        fail("lineage has incomplete transformation artifacts")
    live_hashes = lineage.get("live_authority_sha256")
    if not isinstance(live_hashes, dict) or not live_hashes:
        fail("lineage has no current live-authority byte bindings")
    semantic_refresh = lineage.get("semantic_refresh")
    if semantic_refresh is None:
        if tuple(sorted(live_hashes)) != EXPECTED_LIVE_AUTHORITY_PATHS:
            fail("lineage differs from the fixed live-authority inventory")
        live_binding = json.dumps(live_hashes, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if hashlib.sha256(live_binding).hexdigest() != EXPECTED_LIVE_AUTHORITY_BINDING_SHA256:
            fail("lineage differs from the fixed live-authority binding")
    else:
        check_semantic_refresh(root, lineage, semantic_refresh)
    for relative, expected in live_hashes.items():
        path = root / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            fail(f"live authority bytes changed: {relative}")
    manifest_bytes = (root / MANIFEST_PATH).read_bytes()
    if hashlib.sha256(manifest_bytes).hexdigest() != phase_one.get("manifest_sha256"):
        fail("phase-one manifest hash binding changed")
    object_id = run(root, "git", "hash-object", "--no-filters", str(MANIFEST_PATH)).strip()
    if object_id != phase_one.get("manifest_object"):
        fail("phase-one manifest object binding changed")
    baseline_bytes = artifact_bytes(root, baseline_artifact, baseline_artifact_sha256)
    digest = hashlib.sha256(baseline_bytes).hexdigest()
    if digest != manifest["baseline_sha256"]:
        fail(f"baseline hash mismatch: expected {manifest['baseline_sha256']}, got {digest}")
    baseline_lines = baseline_bytes.decode("utf-8").splitlines()
    entries = manifest.get("entries", [])
    destination_paths = {entry["destination_path"] for entry in entries}
    if set(destination_artifacts) != destination_paths:
        fail("lineage destination artifact inventory differs from manifest")
    required_artifacts = {transformed_artifact, *destination_artifacts.values()}
    if set(artifact_hashes) != required_artifacts:
        fail("lineage transformation artifact hash inventory is incomplete")
    artifact_cache = {
        relative: artifact_bytes(root, relative, artifact_hashes[relative])
        for relative in required_artifacts
    }
    source_owners: set[tuple[str, int]] = set()
    destination_owners: set[tuple[str, int]] = set()
    bundles: list[str] = []
    bundle_contracts: dict[str, tuple[str, str, str, tuple[str, ...]]] = {}
    for index, entry in enumerate(entries, 1):
        source = (entry["source_path"], entry["baseline_line"])
        destination = (entry["destination_path"], entry["destination_line"])
        if entry.get("baseline_git_commit") != revision:
            fail(f"entry baseline commit differs at {source[0]}:{source[1]}")
        if source[0] != source_path:
            fail(f"entry baseline path differs at {source[0]}:{source[1]}")
        if source in source_owners:
            fail(f"duplicate source ownership at {source[0]}:{source[1]}")
        if destination in destination_owners:
            fail(f"duplicate destination ownership at {destination[0]}:{destination[1]}")
        source_owners.add(source)
        destination_owners.add(destination)
        line_number = entry["baseline_line"]
        if not 1 <= line_number <= len(baseline_lines):
            fail(f"manifest entry {index} has invalid baseline line {line_number}")
        exact_text = baseline_lines[line_number - 1]
        if entry["exact_text"] != exact_text:
            fail(f"manifest exact text differs from baseline at {source[0]}:{line_number}")
        expected_hash = hashlib.sha256((exact_text + "\n").encode("utf-8")).hexdigest()
        if entry["content_sha256_utf8_plus_lf"] != expected_hash:
            fail(f"manifest line hash differs at {source[0]}:{line_number}")
        destination_path = entry["destination_path"]
        destination_lines = artifact_cache[destination_artifacts[destination_path]].decode("utf-8").splitlines()
        destination_line = entry["destination_line"]
        if not 1 <= destination_line <= len(destination_lines):
            fail(f"missing destination coordinate: {entry['destination_path']}:{destination_line}")
        if destination_lines[destination_line - 1] != exact_text:
            fail(f"non-verbatim destination at {entry['destination_path']}:{destination_line}")
        if entry.get("verification_result") != "pass":
            fail(f"manifest verification result is not pass at {source[0]}:{line_number}")
        roles = entry.get("role_applicability")
        if not isinstance(roles, list) or not roles or not all(isinstance(role, str) for role in roles):
            fail(f"missing role applicability at {source[0]}:{line_number}")
        trigger = entry.get("disclosure_trigger")
        stub = entry.get("trigger_stub_exact_text")
        if not isinstance(trigger, str) or not trigger or not isinstance(stub, str) or not stub:
            fail(f"missing trigger binding at {source[0]}:{line_number}")
        contract = (entry["destination_path"], trigger, stub, tuple(roles))
        bundle = entry["bundle"]
        if bundle in bundle_contracts and bundle_contracts[bundle] != contract:
            fail(f"inconsistent destination, trigger, or roles for bundle: {bundle}")
        bundle_contracts[bundle] = contract
        if bundle not in bundles:
            bundles.append(bundle)
    mapped = {line for path, line in source_owners if path == source_path}
    upstream_commit = live_overlay.get("upstream_commit")
    if semantic_refresh is None:
        if upstream_commit != EXPECTED_UPSTREAM_COMMIT:
            fail("live overlay differs from the fixed upstream commit authority")
        if upstream_artifact != EXPECTED_UPSTREAM_ARTIFACT or upstream_artifact_sha256 != EXPECTED_UPSTREAM_ARTIFACT_SHA256:
            fail("live overlay differs from the fixed upstream preservation artifact")
    upstream_lines = artifact_bytes(root, upstream_artifact, upstream_artifact_sha256).decode("utf-8").splitlines()
    upstream_counts = collections.Counter(upstream_lines)
    for destination_path in destination_paths:
        preserved_counts = collections.Counter(
            entry["exact_text"]
            for entry in entries
            if entry["destination_path"] == destination_path
        )
        current_counts = collections.Counter(
            (root / destination_path).read_text(encoding="utf-8").splitlines()
        )
        for exact_text, expected_count in preserved_counts.items():
            stable_count = min(expected_count, upstream_counts[exact_text])
            if current_counts[exact_text] < stable_count:
                fail(f"live disclosure lost preserved upstream text: {destination_path}")
    changed = changed_baseline_lines(root, baseline_artifact, transformed_artifact)
    missing = sorted(changed - mapped)
    extra = sorted(mapped - changed)
    if missing:
        fail(f"unmapped changed baseline line: {source_path}:{missing[0]}")
    if extra:
        fail(f"manifest maps unchanged baseline line: {source_path}:{extra[0]}")
    return entries, bundles


def check_triggers(root: Path, entries: list[dict], bundles: list[str]) -> None:
    prompt = run(
        root,
        sys.executable,
        str(root / "bin/fm-prompt-compile.py"),
        "--role",
        "primary",
        "--harness",
        "pi",
        "--runtime",
        "tmux",
        "--root",
        str(root),
    )
    listed = run(root, str(root / "bin/fm-instructions.sh"), "list").splitlines()
    if listed != bundles:
        fail(f"bundle list is missing, dead, duplicated, or reordered: {listed!r}")
    for bundle in bundles:
        entry = next(item for item in entries if item["bundle"] == bundle)
        stub = entry["trigger_stub_exact_text"]
        if prompt.count(stub) != 1:
            fail(f"emitted prompt is missing or duplicates trigger stub for bundle: {bundle}")
        expected = (root / entry["destination_path"]).read_bytes()
        result = subprocess.run(
            [str(root / "bin/fm-instructions.sh"), bundle],
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode or result.stdout != expected:
            fail(f"dead or changed disclosure trigger for bundle: {bundle}")


def check_local_links(root: Path, paths: set[str]) -> int:
    checked = 0
    for relative in sorted(paths):
        path = root / relative
        for match in LINK_RE.finditer(path.read_text(encoding="utf-8")):
            raw_target = match.group(1).split(maxsplit=1)[0].strip("<>")
            if not raw_target or raw_target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            target = raw_target.split("#", 1)[0]
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(root.resolve())
            except ValueError:
                fail(f"local link escapes repository: {relative} -> {raw_target}")
            if not resolved.exists():
                fail(f"broken local link: {relative} -> {raw_target}")
            checked += 1
    return checked


def check_generated_parity(root: Path) -> None:
    result = subprocess.run(
        [str(root / "bin/fm-instructions-generated-parity.sh")],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"changed generated prompt behavior: {detail}")
    sys.stdout.write(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--skip-generated", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        manifest = json.loads((root / MANIFEST_PATH).read_text(encoding="utf-8"))
        lineage = json.loads((root / LINEAGE_PATH).read_text(encoding="utf-8"))
        entries, bundles = check_manifest(root, manifest, lineage)
        check_triggers(root, entries, bundles)
        link_paths = {entry["destination_path"] for entry in entries}
        link_paths.add("docs/verification/prompt-disclosure.md")
        links = check_local_links(root, link_paths)
        if not args.skip_generated:
            check_generated_parity(root)
        print(
            "PASS preservation: "
            f"{len(entries)} changed/removed physical lines, "
            f"{len(bundles)} verbatim bundles, {len(bundles)} live triggers, "
            f"{links} local links"
        )
        return 0
    except (KeyError, json.JSONDecodeError, OSError, VerificationError) as error:
        print(f"fm-instructions-verify: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
