#!/usr/bin/env python3
"""Build a verified, semantically refreshed prompt overlay without moving a branch."""

from __future__ import annotations

import argparse
import base64
import difflib
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import types
from pathlib import Path

SCHEMA = 2


class Refusal(RuntimeError):
    pass


def run(root: Path, *command: str, input_text: str | None = None, check: bool = True) -> str:
    result = subprocess.run(command, cwd=root, text=True, input=input_text, capture_output=True)
    if check and result.returncode:
        raise Refusal(result.stderr.strip() or result.stdout.strip() or "Git command failed")
    return result.stdout.strip()


def root() -> Path:
    result = subprocess.run(("git", "rev-parse", "--show-toplevel"), text=True, capture_output=True)
    if result.returncode:
        raise Refusal("not in a Git worktree")
    return Path(result.stdout.strip()).resolve()


def require_clean(repo: Path) -> None:
    if run(repo, "git", "status", "--porcelain"):
        raise Refusal("dirty working copy")


def commit(repo: Path, revision: str) -> str:
    value = run(repo, "git", "rev-parse", "--verify", f"{revision}^{{commit}}", check=False)
    if len(value) != 40:
        raise Refusal(f"missing commit object: {revision}")
    return value


def ancestor(repo: Path, older: str, newer: str) -> bool:
    result = subprocess.run(("git", "merge-base", "--is-ancestor", older, newer), cwd=repo)
    return result.returncode == 0


def shared_base(repo: Path, overlay: str, upstream: str) -> str:
    bases = run(repo, "git", "merge-base", "--all", overlay, upstream).splitlines()
    if len(bases) != 1:
        raise Refusal("overlay and upstream must have exactly one shared Git base")
    return commit(repo, bases[0])


def tree_entry(repo: Path, revision: str, path: str) -> dict | None:
    output = run(repo, "git", "ls-tree", revision, "--", path)
    if not output:
        return None
    left, found = output.split("\t", 1)
    mode, kind, oid = left.split()
    if found != path or kind not in {"blob", "commit"}:
        raise Refusal(f"malformed tree entry: {revision}:{path}")
    return {"mode": mode, "type": kind, "oid": oid}


def changed_paths(repo: Path, old: str, new: str) -> set[str]:
    return set(filter(None, run(repo, "git", "diff", "--name-only", old, new).splitlines()))


def blob(repo: Path, entry: dict | None) -> bytes | None:
    if entry is None or entry["type"] != "blob":
        return None
    result = subprocess.run(("git", "cat-file", "blob", entry["oid"]), cwd=repo, capture_output=True)
    if result.returncode:
        raise Refusal("missing overlay blob")
    return result.stdout


def edits(base: list[bytes], changed: list[bytes]) -> list[tuple[int, int, list[bytes]]]:
    matcher = difflib.SequenceMatcher(None, base, changed, autojunk=False)
    return [(i1, i2, changed[j1:j2]) for tag, i1, i2, j1, j2 in matcher.get_opcodes() if tag != "equal"]


def edits_overlap(left: tuple[int, int, list[bytes]], right: tuple[int, int, list[bytes]]) -> bool:
    left_start, left_end, _ = left
    right_start, right_end, _ = right
    if left_start == left_end and right_start == right_end:
        return left_start == right_start
    if left_start == left_end:
        return right_start < left_start < right_end
    if right_start == right_end:
        return left_start < right_start < left_end
    return max(left_start, right_start) < min(left_end, right_end)


def disjoint_merge(base: bytes, overlay: bytes, upstream: bytes) -> bytes | None:
    if b"\0" in base or b"\0" in overlay or b"\0" in upstream:
        return None
    base_lines = base.splitlines(keepends=True)
    overlay_edits = edits(base_lines, overlay.splitlines(keepends=True))
    upstream_edits = edits(base_lines, upstream.splitlines(keepends=True))
    if any(edits_overlap(left, right) for left in overlay_edits for right in upstream_edits):
        return None
    merged = list(base_lines)
    combined = sorted(overlay_edits + upstream_edits, key=lambda item: (item[0], item[1]), reverse=True)
    for start, end, replacement in combined:
        merged[start:end] = replacement
    return b"".join(merged)


def object_id(repo: Path, content: bytes, write: bool = False) -> str:
    command = ["git", "hash-object"]
    if write:
        command.append("-w")
    command.append("--stdin")
    result = subprocess.run(command, cwd=repo, input=content, capture_output=True)
    if result.returncode:
        raise Refusal(result.stderr.decode(errors="replace").strip() or "cannot hash merged owner object")
    return result.stdout.decode().strip()


def classify_record(
    repo: Path,
    path: str,
    entries: tuple[dict | None, dict | None, dict | None],
    authority: dict,
    composable: set[str],
) -> dict:
    base_entry, upstream_entry, overlay_entry = entries
    record = {"path": path, "base": base_entry, "upstream": upstream_entry, "overlay": overlay_entry}
    if overlay_entry == base_entry or upstream_entry == base_entry or overlay_entry == upstream_entry:
        record["classification"] = "overlay-owner" if overlay_entry != base_entry else "upstream-owner"
        return record
    overlay_blob = blob(repo, overlay_entry)
    if overlay_blob is not None and hashlib.sha256(overlay_blob).hexdigest() == authority.get(path):
        record["classification"] = "overlay-owner"
        return record
    same_mode = base_entry and overlay_entry and upstream_entry and base_entry["mode"] == overlay_entry["mode"] == upstream_entry["mode"]
    merged = disjoint_merge(blob(repo, base_entry) or b"", overlay_blob or b"", blob(repo, upstream_entry) or b"") if path in composable and same_mode else None
    if merged is None:
        record["classification"] = "ambiguous-semantic-owner"
        return record
    record["classification"] = "disjoint-owner-merge"
    record["merged"] = {"mode": overlay_entry["mode"], "type": "blob", "oid": object_id(repo, merged)}
    record["merged_base64"] = base64.b64encode(merged).decode("ascii")
    return record


def digest(value: dict) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def semantic_refresh(repo: Path, previous: str, upstream: str, overlay: str, lineage: Path) -> dict:
    """Cross the semantic-refresh module's single transformation interface."""
    module_path = Path(__file__).resolve().with_name("fm-prompt-semantic-refresh.py")
    if not module_path.is_file():
        raise Refusal("semantic refresh owner is unavailable")
    module = types.ModuleType("fm_prompt_semantic_refresh")
    module.__file__ = str(module_path)
    exec(compile(module_path.read_bytes(), str(module_path), "exec"), module.__dict__)
    try:
        return module.refresh(
            repo,
            argparse.Namespace(
                previous_upstream=previous,
                upstream=upstream,
                overlay=overlay,
                lineage=lineage,
            ),
        )
    except module.Refusal as error:
        raise Refusal(str(error)) from error


def load_lineage(repo: Path, path: Path) -> dict:
    value = json.loads((repo / path).read_text())
    if value.get("schema_version") != 4:
        raise Refusal("unsupported or malformed lineage graph")
    generations = value.get("generations")
    if not isinstance(generations, list) or not generations:
        raise Refusal("lineage graph has no generations")
    numbers = [item.get("generation") for item in generations]
    if numbers != list(range(len(numbers))):
        raise Refusal("lineage generations are not contiguous")
    paths = value.get("overlay_paths")
    if not isinstance(paths, list) or not paths or len(paths) != len(set(paths)):
        raise Refusal("lineage overlay path inventory is malformed")
    authority = value.get("live_authority_sha256", {})
    if not isinstance(authority, dict) or not set(authority).issubset(paths):
        raise Refusal("lineage live-authority manifest is malformed")
    if any(not isinstance(item, str) or len(item) != 64 or any(char not in "0123456789abcdef" for char in item) for item in authority.values()):
        raise Refusal("lineage live-authority manifest is malformed")
    composable = value.get("disjoint_merge_paths", [])
    if not isinstance(composable, list) or len(composable) != len(set(composable)) or not set(composable).issubset(paths):
        raise Refusal("lineage disjoint-merge path manifest is malformed")
    return value


def make_plan(repo: Path, args: argparse.Namespace) -> dict:
    require_clean(repo)
    if args.fetch:
        run(repo, "git", "fetch", "--prune", args.remote, args.branch)
    previous = commit(repo, args.previous_upstream)
    upstream = commit(repo, args.upstream)
    overlay = commit(repo, args.overlay)
    if not ancestor(repo, previous, upstream) or not ancestor(repo, previous, overlay):
        raise Refusal("malformed or unrelated commit graph")
    ownership_base = shared_base(repo, overlay, upstream)
    if not ancestor(repo, previous, ownership_base):
        raise Refusal("shared Git base predates the lineage provenance baseline")
    lineage_path = (repo / args.lineage).resolve()
    try:
        lineage_relative = lineage_path.relative_to(repo).as_posix()
    except ValueError:
        raise Refusal("lineage graph must be inside the repository") from None
    lineage = load_lineage(repo, Path(lineage_relative))
    registered = set(lineage["overlay_paths"])
    live = next(
        (item for item in lineage["generations"] if item.get("kind") == "live-overlay"),
        None,
    )
    if live is None or live.get("upstream_commit") != previous:
        raise Refusal("lineage generated-parity baseline does not match previous upstream")
    if lineage_relative not in registered:
        raise Refusal("tracked lineage graph is absent from its overlay path inventory")
    result = subprocess.run(
        ("git", "show", f"{overlay}:{lineage_relative}"),
        cwd=repo,
        capture_output=True,
    )
    if result.returncode or result.stdout != lineage_path.read_bytes():
        raise Refusal("overlay commit does not contain the exact lineage graph used for planning")
    local_paths = changed_paths(repo, ownership_base, overlay)
    upstream_paths = changed_paths(repo, ownership_base, upstream)
    unregistered = sorted(local_paths - registered)
    if unregistered:
        raise Refusal(f"unregistered local overlay path: {unregistered[0]}")
    refresh = semantic_refresh(repo, previous, upstream, overlay, Path(lineage_relative))
    semantic_updates = {item["path"]: item for item in refresh["updates"]}
    records = []
    ambiguous = []
    authority = lineage.get("live_authority_sha256", {})
    composable = set(lineage.get("disjoint_merge_paths", []))
    all_paths = sorted(local_paths | upstream_paths | registered | set(semantic_updates))
    for path in all_paths:
        entries = (tree_entry(repo, ownership_base, path), tree_entry(repo, upstream, path), tree_entry(repo, overlay, path))
        if path in semantic_updates:
            update = semantic_updates[path]
            content = base64.b64decode(update["content_base64"], validate=True)
            if hashlib.sha256(content).hexdigest() != update["sha256"]:
                raise Refusal(f"semantic refresh bytes differ from their proof: {path}")
            mode_entry = entries[2] or entries[1]
            mode = mode_entry["mode"] if mode_entry else update["mode"]
            record = {
                "path": path,
                "base": entries[0],
                "upstream": entries[1],
                "overlay": entries[2],
                "classification": "semantic-refresh-owner",
                "merged": {"mode": mode, "type": "blob", "oid": object_id(repo, content)},
                "merged_base64": update["content_base64"],
            }
        else:
            record = classify_record(repo, path, entries, authority, composable)
        records.append(record)
        if record["classification"] == "ambiguous-semantic-owner":
            ambiguous.append(path)
    return {
        "schema_version": SCHEMA,
        "previous_upstream": previous,
        "ownership_base": ownership_base,
        "upstream": upstream,
        "overlay": overlay,
        "lineage_path": lineage_relative,
        "lineage_sha256": hashlib.sha256(lineage_path.read_bytes()).hexdigest(),
        "resolution_policy": "semantic-owner-only; never ours-or-theirs",
        "semantic_refresh": {key: refresh[key] for key in ("schema_version", "previous_upstream", "upstream", "overlay", "transformer_sha256", "changes")},
        "records": records,
        "ambiguous": ambiguous,
    }


def write_plan(repo: Path, args: argparse.Namespace) -> None:
    value = make_plan(repo, args)
    output = repo / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(f"CHECK upstream={value['upstream']} overlay={value['overlay']} records={len(value['records'])} ambiguous={len(value['ambiguous'])}")


def load_plan(repo: Path, path: Path) -> dict:
    value = json.loads((repo / path).read_text())
    if value.get("schema_version") != SCHEMA or value.get("resolution_policy") != "semantic-owner-only; never ours-or-theirs":
        raise Refusal("malformed plan or automatic ours/theirs policy")
    lineage_path = value.get("lineage_path")
    revisions = {key: value.get(key) for key in ("previous_upstream", "upstream", "overlay")}
    if (
        not isinstance(lineage_path, str)
        or not lineage_path
        or not isinstance(value.get("ownership_base"), str)
        or not all(isinstance(revision, str) for revision in revisions.values())
    ):
        raise Refusal("malformed plan inputs")
    canonical = make_plan(
        repo,
        argparse.Namespace(
            fetch=False,
            previous_upstream=revisions["previous_upstream"],
            upstream=revisions["upstream"],
            overlay=revisions["overlay"],
            lineage=Path(lineage_path),
        ),
    )
    if value != canonical:
        raise Refusal("plan differs from canonical commit and lineage reconstruction")
    if canonical["ambiguous"]:
        raise Refusal(f"ambiguous safety or semantic-owner change: {canonical['ambiguous'][0]}")
    return value


def build_tree(repo: Path, plan: dict) -> str:
    with tempfile.TemporaryDirectory(prefix="fm-overlay-index-") as directory:
        index_path = str(Path(directory) / "index")
        env = dict(os.environ, GIT_INDEX_FILE=index_path)
        def git(*args: str, text: str | None = None) -> str:
            result = subprocess.run(("git", *args), cwd=repo, env=env, text=True, input=text, capture_output=True)
            if result.returncode:
                raise Refusal(result.stderr.strip() or "temporary-index operation failed")
            return result.stdout.strip()
        git("read-tree", plan["upstream"])
        for record in plan["records"]:
            if record["classification"] not in {"overlay-owner", "disjoint-owner-merge", "semantic-refresh-owner"}:
                continue
            entry = record["overlay"] if record["classification"] == "overlay-owner" else record["merged"]
            path = record["path"]
            if record["classification"] in {"disjoint-owner-merge", "semantic-refresh-owner"}:
                content = base64.b64decode(record["merged_base64"], validate=True)
                written = object_id(repo, content, write=True)
                if written != entry["oid"]:
                    raise Refusal("transformed owner object differs from the canonical plan")
            if entry is None:
                git("update-index", "--force-remove", "--", path)
            else:
                git("update-index", "--add", "--cacheinfo", entry["mode"], entry["oid"], path)
        return git("write-tree")


def rebuild(repo: Path, args: argparse.Namespace) -> None:
    if not args.candidate_ref.startswith("refs/firstmate/overlays/candidates/"):
        raise Refusal("candidate ref must be under refs/firstmate/overlays/candidates/")
    disclosure_owner = repo / "bin/fm-operation-disclosure.py"
    if not disclosure_owner.is_file():
        raise Refusal("overlay rebuild disclosure owner is unavailable")
    disclosure = subprocess.run(
        [sys.executable, str(disclosure_owner), "consume", "overlay-rebuild", args.candidate_ref, "--", *sys.argv[1:]],
        cwd=repo,
    )
    if disclosure.returncode:
        raise Refusal("overlay rebuild disclosure was refused")
    require_clean(repo)
    plan = load_plan(repo, args.plan)
    if run(repo, "git", "symbolic-ref", "--quiet", args.candidate_ref, check=False):
        raise Refusal("candidate ref must not be symbolic")
    tree = build_tree(repo, plan)
    message = f"Firstmate prompt overlay for {plan['upstream']}\n\nPlan-SHA256: {digest(plan)}\n"
    candidate = run(repo, "git", "commit-tree", tree, "-p", plan["upstream"], input_text=message + "\n")
    old = run(repo, "git", "rev-parse", "--verify", args.candidate_ref, check=False)
    command = ["git", "update-ref", "--no-deref", args.candidate_ref, candidate]
    if old:
        command.append(old)
    run(repo, *command)
    print(f"REBUILT candidate={candidate} upstream={plan['upstream']} ref={args.candidate_ref}")


def verify(repo: Path, args: argparse.Namespace) -> str:
    require_clean(repo)
    plan = load_plan(repo, args.plan)
    candidate = commit(repo, args.candidate_ref)
    parents = run(repo, "git", "show", "-s", "--format=%P", candidate).split()
    if parents != [plan["upstream"]]:
        raise Refusal("candidate is not a single-parent child of the exact upstream")
    expected_tree = build_tree(repo, plan)
    actual_tree = run(repo, "git", "show", "-s", "--format=%T", candidate)
    if actual_tree != expected_tree:
        raise Refusal("candidate tree or executable modes do not match the plan")
    token_payload = {"candidate": candidate, "upstream": plan["upstream"], "plan_sha256": digest(plan), "checks": ["graph", "objects", "owners", "modes", "lineage"]}
    token = digest(token_payload)
    print(f"VERIFIED candidate={candidate} upstream={plan['upstream']} token={token}")
    return token


def ready(repo: Path, args: argparse.Namespace) -> None:
    token = verify(repo, args)
    if args.token != token:
        raise Refusal("missing or stale verification token")
    candidate = commit(repo, args.candidate_ref)
    plan = load_plan(repo, args.plan)
    print(f"READY candidate={candidate} upstream={plan['upstream']} previous_overlay={plan['overlay']}")


def update_ref_input(updates: list[tuple[str, str, str]]) -> str:
    lines = ["start"]
    lines.extend(f"update {ref} {new} {old}" for ref, new, old in updates)
    return "\n".join((*lines, "prepare", "commit", ""))


def install(repo: Path, args: argparse.Namespace) -> None:
    if not args.candidate_ref.startswith("refs/firstmate/overlays/candidates/"):
        raise Refusal("candidate ref must be under refs/firstmate/overlays/candidates/")
    disclosure_owner = repo / "bin/fm-operation-disclosure.py"
    if not disclosure_owner.is_file():
        raise Refusal("overlay installation disclosure owner is unavailable")
    disclosure = subprocess.run(
        [sys.executable, str(disclosure_owner), "consume", "overlay-install", args.candidate_ref, "--", *sys.argv[1:]],
        cwd=repo,
    )
    if disclosure.returncode:
        raise Refusal("overlay installation disclosure was refused")
    protected_refs = (args.candidate_ref, "refs/firstmate/overlays/live", "refs/firstmate/overlays/previous")
    symbolic = next((ref for ref in protected_refs if run(repo, "git", "symbolic-ref", "--quiet", ref, check=False)), None)
    if symbolic:
        raise Refusal(f"overlay ref must not be symbolic: {symbolic}")
    candidate = commit(repo, args.candidate_ref)
    if args.approve_candidate != candidate:
        raise Refusal("explicit installation approval does not name the exact candidate")
    token = verify(repo, args)
    if args.token != token:
        raise Refusal("missing or stale verification token")
    plan = load_plan(repo, args.plan)
    branch_ref = run(repo, "git", "symbolic-ref", "--quiet", "HEAD", check=False)
    if branch_ref != "refs/heads/main":
        raise Refusal("installation requires the checked-out main branch")
    installed = commit(repo, "HEAD")
    if installed != plan["overlay"]:
        raise Refusal("installed overlay differs from the ready plan")
    if commit(repo, "origin/main") != plan["upstream"]:
        raise Refusal("origin/main advanced after readiness verification")
    live_ref = "refs/firstmate/overlays/live"
    previous_ref = "refs/firstmate/overlays/previous"
    live = run(repo, "git", "rev-parse", "--verify", live_ref, check=False) or "0" * 40
    previous = run(repo, "git", "rev-parse", "--verify", previous_ref, check=False) or "0" * 40
    run(repo, "git", "read-tree", "-m", "-u", installed, candidate)
    updates = [(branch_ref, candidate, installed), (live_ref, candidate, live), (previous_ref, installed, previous)]
    result = subprocess.run(("git", "update-ref", "--stdin"), cwd=repo, text=True, input=update_ref_input(updates), capture_output=True)
    if result.returncode:
        rollback = subprocess.run(("git", "read-tree", "-m", "-u", candidate, installed), cwd=repo, capture_output=True, text=True)
        detail = result.stderr.strip() or "atomic ref update failed"
        if rollback.returncode:
            detail += "; working-copy rollback failed"
        raise Refusal(detail)
    print(f"INSTALLED candidate={candidate} upstream={plan['upstream']} previous_overlay={installed}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("--previous-upstream", required=True)
    check.add_argument("--upstream", default="origin/main")
    check.add_argument("--overlay", required=True)
    check.add_argument("--lineage", type=Path, default=Path("docs/verification/prompt-lineage.json"))
    check.add_argument("--output", type=Path, required=True)
    check.add_argument("--fetch", action="store_true")
    check.add_argument("--remote", default="origin")
    check.add_argument("--branch", default="main")
    check.set_defaults(function=write_plan)
    for name, function in (("rebuild", rebuild), ("verify", verify), ("ready", ready), ("install", install)):
        command = commands.add_parser(name)
        command.add_argument("--plan", type=Path, required=True)
        command.add_argument("--candidate-ref", required=True)
        if name in {"ready", "install"}:
            command.add_argument("--token", required=True)
        if name == "install":
            command.add_argument("--approve-candidate", required=True)
        command.set_defaults(function=function)
    return result


def main() -> int:
    args = parser().parse_args()
    repo = root()
    try:
        args.function(repo, args)
    except (OSError, json.JSONDecodeError, Refusal) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
