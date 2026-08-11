#!/usr/bin/env bash
# Create and verify literal Python test-declaration receipts for a project.
#
# Usage: fm-test-inventory.sh collect <project-root>
#        fm-test-inventory.sh check <project-root>
#        fm-test-inventory.sh merge-check <project-root> <candidate-sha> <base-sha>
#
# This tool never imports or executes candidate project code.
# `collect` writes a receipt from literal Python source and `check` verifies it.
# In a Git worktree, `collect` and `check` inspect only regular stage-0 test
# blobs in the index and report `source_tree=git-index`; outside Git, they report
# `source_tree=filesystem`.
# `merge-check` additionally binds declarations and receipts to clean exact Git
# candidate and base commits before the shared merge boundary proceeds.
# Only an exact base with no declaration may use the candidate-carried bootstrap.
set -eu

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
MODE=${1:-}
PROJECT=${2:-}
case "$MODE" in
  collect|check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; CANDIDATE=; BASE= ;;
  merge-check) [ "$#" -eq 4 ] || { usage >&2; exit 2; }; CANDIDATE=$3; BASE=$4 ;;
  *) usage >&2; exit 2 ;;
esac
[ -d "$PROJECT" ] || { echo "error: project root is unavailable: $PROJECT" >&2; exit 1; }

python3 - "$MODE" "$PROJECT" "$CANDIDATE" "$BASE" <<'PY'
import ast
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import sys

mode, root_arg, candidate_sha, base_sha = sys.argv[1:]
root = pathlib.Path(root_arg).resolve()
declaration_rel = ".firstmate/test-inventory.json"
receipt_rel = ".firstmate/test-inventory-receipt.json"
declaration_path = root / declaration_rel
receipt_path = root / receipt_rel


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(command, check=True):
    result = subprocess.run(command, cwd=root, text=True, capture_output=True)
    if check and result.returncode:
        fail(f"{' '.join(command)} failed: {(result.stderr or result.stdout).strip()}")
    return result


def git(*args, check=True):
    return run(["git", *args], check=check)


def git_bytes(*args, check=True):
    result = subprocess.run(["git", *args], cwd=root, capture_output=True)
    if check and result.returncode:
        message = (result.stderr or result.stdout).decode("utf-8", errors="replace").strip()
        fail(f"git {' '.join(args)} failed: {message}")
    return result


def load_json_bytes(raw, label):
    def reject_duplicate_keys(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate object key: {key}")
            value[key] = item
        return value

    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        fail(f"{label} is invalid: {error}")


def load_json(path, label, required=True):
    if path.is_symlink():
        fail(f"{label} must not be a symlink: {path}")
    try:
        return load_json_bytes(path.read_bytes(), label)
    except FileNotFoundError:
        if not required:
            return None
        fail(f"{label} is unavailable: {path}")
    except OSError as error:
        fail(f"{label} is invalid: {error}")


def load_json_at(revision, relative_path, label, required=True):
    listing = git_bytes("ls-tree", "-z", "--full-tree", revision, "--", relative_path).stdout
    entries = [entry for entry in listing.split(b"\0") if entry]
    if not entries:
        if not required:
            return None
        fail(f"{label} is unavailable at {revision}: {relative_path}")
    if len(entries) != 1:
        fail(f"{label} is ambiguous at {revision}: {relative_path}")
    try:
        header, raw_path = entries[0].split(b"\t", 1)
        file_mode, object_type, object_id = header.decode("ascii").split()
        tree_path = raw_path.decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        fail(f"cannot inspect {label} at {revision}: {error}")
    if tree_path != relative_path:
        fail(f"{label} is ambiguous at {revision}: {relative_path}")
    if object_type != "blob" or file_mode not in {"100644", "100755"}:
        fail(f"{label} must be a regular file at {revision}: {relative_path}")
    return load_json_bytes(git_bytes("cat-file", "blob", object_id).stdout, label)


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def nonnegative_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def validate_declaration(declaration):
    if not isinstance(declaration, dict) or declaration.get("schema_version") != 1:
        fail("test-inventory declaration must have schema_version=1")
    status = declaration.get("status")
    if status not in {"test-bearing", "testless"}:
        fail("test-inventory declaration status must be test-bearing or testless")
    if status == "testless":
        if set(declaration) != {"schema_version", "status"}:
            fail("a testless declaration may contain only schema_version and status")
        return {"status": status}
    baseline = declaration.get("baseline")
    if not isinstance(baseline, dict) or not positive_integer(baseline.get("version")):
        fail("test-bearing declaration must provide a positive baseline.version")
    if not positive_integer(baseline.get("declarations")) or not positive_integer(baseline.get("test_files")):
        fail("test-bearing baseline declarations and test_files must both be positive")
    allowed = declaration.get("maximum_unreviewed_deletion")
    if not nonnegative_integer(allowed):
        fail("maximum_unreviewed_deletion must be a nonnegative integer")
    review = declaration.get("baseline_reduction_review")
    if review is not None:
        if not isinstance(review, dict):
            fail("baseline_reduction_review must be an object")
        for key in ("from_version", "from_declarations", "from_test_files"):
            if not positive_integer(review.get(key)):
                fail(f"baseline_reduction_review.{key} must be positive")
        if review["from_version"] >= baseline["version"]:
            fail("baseline_reduction_review must advance baseline.version")
        if baseline["declarations"] >= review["from_declarations"] and baseline["test_files"] >= review["from_test_files"]:
            fail("baseline_reduction_review is allowed only for an actual baseline reduction")
        for key in ("reviewed_by", "reviewed_at", "reason"):
            if not nonempty_string(review.get(key)):
                fail(f"baseline_reduction_review.{key} must be recorded")
    return {"status": status, "baseline": baseline, "allowed": allowed, "review": review}


def validate_transition(base_declaration, candidate_declaration):
    base = validate_declaration(base_declaration)
    candidate = validate_declaration(candidate_declaration)
    if base["status"] == "testless" or candidate["status"] == "testless":
        if base["status"] != candidate["status"]:
            fail("test-inventory status changes require a separately reviewed migration")
        return candidate
    base_values = (base["baseline"]["declarations"], base["baseline"]["test_files"], base["allowed"])
    candidate_values = (candidate["baseline"]["declarations"], candidate["baseline"]["test_files"], candidate["allowed"])
    if candidate_values == base_values:
        if candidate["baseline"]["version"] != base["baseline"]["version"]:
            fail("baseline.version may advance only with a baseline policy change")
        return candidate
    if candidate["baseline"]["version"] <= base["baseline"]["version"]:
        fail("a changed test-inventory baseline must advance baseline.version")
    reduced = candidate_values[0] < base_values[0] or candidate_values[1] < base_values[1] or candidate_values[2] > base_values[2]
    if not reduced:
        return candidate
    review = candidate["review"]
    if review is None:
        fail("test-inventory policy reduction requires baseline_reduction_review")
    expected = {"from_version": base["baseline"]["version"], "from_declarations": base_values[0], "from_test_files": base_values[1]}
    for key, value in expected.items():
        if review.get(key) != value:
            fail(f"baseline_reduction_review.{key} must match the merge-base declaration")
    return candidate


def is_test_source(relative):
    if any(part in {".git", ".venv", "venv", "site-packages", "__pycache__"} for part in relative.parts):
        return False
    return relative.name.startswith("test_") or relative.name.endswith("_test.py")


def filesystem_sources():
    sources = []
    for path in root.rglob("*.py"):
        relative = path.relative_to(root)
        if not is_test_source(relative):
            continue
        if path.is_symlink():
            fail(f"literal Python test source must not be a symlink: {relative.as_posix()}")
        try:
            sources.append((relative.as_posix(), path.read_bytes()))
        except OSError as error:
            fail(f"cannot read literal Python test source {relative.as_posix()}: {error}")
    return sorted(sources)


def git_worktree_sources():
    top = pathlib.Path(git("rev-parse", "--show-toplevel").stdout.strip()).resolve()
    if top != root:
        fail(f"Git worktree inventory requires the checkout root: {root} != {top}")
    sources = []
    entries = git_bytes("ls-files", "-s", "-z", "--cached").stdout.split(b"\0")
    for entry in entries:
        if not entry:
            continue
        try:
            header, raw_path = entry.split(b"\t", 1)
            file_mode, object_id, stage = header.decode("ascii").split()
            relative = pathlib.PurePosixPath(raw_path.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            fail(f"cannot inspect Git-indexed path: {error}")
        if relative.suffix != ".py" or not is_test_source(relative):
            continue
        if stage != "0" or file_mode not in {"100644", "100755"}:
            fail(f"literal Python test source must be a regular stage-0 file in the Git index: {relative.as_posix()}")
        sources.append((relative.as_posix(), git_bytes("cat-file", "blob", object_id).stdout))
    return sorted(sources)


def worktree_source_tree():
    inside_worktree = git("rev-parse", "--is-inside-work-tree", check=False)
    if inside_worktree.returncode == 0 and inside_worktree.stdout.strip() == "true":
        top = pathlib.Path(git("rev-parse", "--show-toplevel").stdout.strip()).resolve()
        if top != root:
            fail(f"Git worktree inventory requires the checkout root: {root} != {top}")
        return "git-index"
    return "filesystem"


def tree_sources(revision):
    sources = []
    listing = git_bytes("ls-tree", "-rz", "--full-tree", revision).stdout
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        try:
            header, raw_path = entry.split(b"\t", 1)
            file_mode, object_type, object_id = header.decode("ascii").split()
            relative = pathlib.PurePosixPath(raw_path.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            fail(f"cannot inspect candidate tree entry: {error}")
        if relative.suffix != ".py" or not is_test_source(relative):
            continue
        if object_type != "blob" or file_mode not in {"100644", "100755"}:
            fail(f"literal Python test source must be a regular file at {revision}: {relative.as_posix()}")
        sources.append((relative.as_posix(), git_bytes("cat-file", "blob", object_id).stdout))
    return sorted(sources)


def declaration_nodes(relative, raw):
    try:
        tree = ast.parse(raw.decode("utf-8"), filename=relative)
    except (SyntaxError, UnicodeDecodeError) as error:
        fail(f"cannot parse literal Python test source {relative}: {error}")
    nodes = []
    for item in tree.body:
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name.startswith("test_"):
            nodes.append(f"{relative}::{item.name}")
        elif isinstance(item, ast.ClassDef) and item.name.startswith("Test"):
            for member in item.body:
                if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)) and member.name.startswith("test_"):
                    nodes.append(f"{relative}::{item.name}::{member.name}")
    return nodes


def observed_inventory(revision=None, source_tree=None):
    nodes = []
    if revision:
        sources = tree_sources(revision)
    elif source_tree == "git-index":
        sources = git_worktree_sources()
    else:
        sources = filesystem_sources()
    for relative, raw in sources:
        nodes.extend(declaration_nodes(relative, raw))
    if not nodes:
        fail("declared test-bearing project has no literal Python test declarations")
    if len(nodes) != len(set(nodes)):
        fail("literal Python test declarations are not unique")
    nodes.sort()
    files = {node.split("::", 1)[0] for node in nodes}
    digest = hashlib.sha256(("\n".join(nodes) + "\n").encode("utf-8")).hexdigest()
    return {"declarations": len(nodes), "test_files": len(files), "literal_declarations_sha256": digest}


def require_clean_exact_checkout():
    top = pathlib.Path(git("rev-parse", "--show-toplevel").stdout.strip()).resolve()
    if top != root:
        fail(f"project root does not match its git top-level: {root} != {top}")
    resolved_candidate = git("rev-parse", "--verify", f"{candidate_sha}^{{commit}}").stdout.strip()
    resolved_base = git("rev-parse", "--verify", f"{base_sha}^{{commit}}").stdout.strip()
    if resolved_candidate != candidate_sha or resolved_base != base_sha:
        fail("merge inventory requires full exact candidate and base commit SHAs")
    if git("rev-parse", "HEAD").stdout.strip() != candidate_sha:
        fail("task worktree HEAD does not match the merge candidate SHA")
    if git("merge-base", "--is-ancestor", base_sha, candidate_sha, check=False).returncode:
        fail("merge candidate does not contain the exact merge-base SHA")
    if git("status", "--porcelain", "--untracked-files=all").stdout:
        fail("task worktree is dirty; refusing test-inventory merge verification")


def verify_receipt(declaration, policy, receipt, revision=None, source_tree=None):
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1:
        fail("test-inventory receipt must have schema_version=1")
    if receipt.get("declaration_sha256") != canonical_hash(declaration):
        fail("test-inventory receipt does not match the versioned declaration")
    if receipt.get("baseline_version") != policy["baseline"]["version"]:
        fail("test-inventory receipt does not match the declared baseline version")
    if not re.fullmatch(r"[0-9a-f]{64}", str(receipt.get("literal_declarations_sha256", ""))):
        fail("test-inventory receipt must record literal_declarations_sha256")
    expected_receipt_source_tree = "git-index" if revision else source_tree
    if receipt.get("source_tree") != expected_receipt_source_tree:
        fail(f"test-inventory receipt source_tree must be {expected_receipt_source_tree}")
    for key in ("declarations", "test_files"):
        if not positive_integer(receipt.get(key)):
            fail(f"test-inventory receipt {key} must be positive")
    observed = observed_inventory(revision, source_tree)
    for key in ("declarations", "test_files", "literal_declarations_sha256"):
        if receipt.get(key) != observed[key]:
            fail(f"current literal Python {key} does not match the committed receipt; regenerate it before merging")
    if receipt["declarations"] < policy["baseline"]["declarations"] - policy["allowed"] or receipt["test_files"] < policy["baseline"]["test_files"] - policy["allowed"]:
        fail("test inventory dropped below the declared floor; record a reviewed baseline_reduction_review before merging")
    return observed


source_tree = worktree_source_tree()

if mode == "merge-check":
    require_clean_exact_checkout()
    base_declaration = load_json_at(base_sha, declaration_rel, "merge-base test-inventory declaration", required=False)
    declaration = load_json_at(candidate_sha, declaration_rel, "candidate test-inventory declaration")
    if base_declaration is None:
        validate_declaration(declaration)
    else:
        validate_transition(base_declaration, declaration)
    if load_json(declaration_path, "test-inventory declaration") != declaration:
        fail("worktree test-inventory declaration does not match the exact candidate commit")
else:
    declaration = load_json(declaration_path, "test-inventory declaration")
policy = validate_declaration(declaration)
bootstrap = mode == "merge-check" and base_declaration is None

if policy["status"] == "testless":
    if receipt_path.exists() or (mode == "merge-check" and load_json_at(candidate_sha, receipt_rel, "candidate test-inventory receipt", required=False) is not None):
        fail("a testless declaration must not keep a test-inventory receipt")
    suffix = " bootstrap-seed" if bootstrap else ""
    print(f"test inventory: source_tree={source_tree} declared testless{suffix}")
    raise SystemExit(0)

if mode == "collect":
    observed = observed_inventory(source_tree=source_tree)
    receipt = {"schema_version": 1, "declaration_sha256": canonical_hash(declaration), "baseline_version": policy["baseline"]["version"], "source_tree": source_tree, **observed, "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()}
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"test inventory: source_tree={source_tree} declarations={receipt['declarations']} test_files={receipt['test_files']}")
    raise SystemExit(0)

receipt = load_json(receipt_path, "test-inventory receipt")
if mode == "merge-check" and receipt != load_json_at(candidate_sha, receipt_rel, "candidate test-inventory receipt"):
    fail("worktree test-inventory receipt does not match the exact candidate commit")
verified = verify_receipt(declaration, policy, receipt, candidate_sha if mode == "merge-check" else None, source_tree)
suffix = " bootstrap-seed" if bootstrap else ""
print(f"test inventory: source_tree={source_tree} declarations={verified['declarations']} test_files={verified['test_files']} accepted{suffix}")
PY
