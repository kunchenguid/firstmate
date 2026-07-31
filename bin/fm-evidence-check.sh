#!/usr/bin/env bash
# fm-evidence-check.sh - refuse a byte-identical before/after evidence image pair.
#
# A before/after image pair that is byte-identical is deterministic proof that
# no visual verification actually happened, even when the files exist and are
# correctly named. This scans for the two before/after naming conventions in
# use across the fleet's history - before-<suffix> / after-<suffix>, and the
# reversed <prefix>-before / <prefix>-after - pairs images that share a suffix
# or prefix in the same directory, and compares content.
#
# An unpaired image (a legitimate after-only set, or any image that does not
# follow either convention) is never a failure and is silently ignored.
#
# Usage:
#   fm-evidence-check.sh --ref <git-ref> [--root <repo>] [--] [<pathspec>...]
#   fm-evidence-check.sh --local [--] <path>...
#
#   --ref <ref>     Compare images as committed at <ref> using git ls-tree blob
#                    OIDs, so identical content is proven from metadata alone
#                    with no blob download or hashing. Repo root defaults to
#                    the current directory; override with --root.
#   --root <repo>   Git repository to run ls-tree against in --ref mode.
#   --local         Compare files/directories given directly on disk by content
#                    hash (sha256, falling back to shasum), for when no git ref
#                    is available.
#   <pathspec>...   Optional git pathspecs restricting --ref discovery to a
#                    subtree (default: the whole tree at <ref>).
#   <path>...       Files or directories to scan recursively in --local mode.
#
# A genuinely intentional identical pair (a change with no visual difference)
# is a real case, not a bug, so it is not silently ignored either: refuse it by
# default, and let it through only via an explicit, greppable opt-out. Commit
# (or place, in --local mode) a zero-byte marker file named after the "after"
# image with ".allow-identical" appended, e.g. for after-x.png the marker is
# after-x.png.allow-identical alongside it.
#
# Exit 0: no evidence images, no before/after pairs, or every identical pair
#         carries its .allow-identical marker.
# Exit 1: at least one before/after pair is byte-identical with no marker.
# Exit 2: usage error, or the git ref/repo could not be read.
set -eu

usage() {
  cat <<'USAGE' >&2
usage: fm-evidence-check.sh --ref <git-ref> [--root <repo>] [--] [<pathspec>...]
       fm-evidence-check.sh --local [--] <path>...
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

MODE=
REF=
ROOT=$(pwd)

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      [ $# -ge 2 ] || { usage; exit 2; }
      MODE=ref
      REF=$2
      shift 2
      ;;
    --root)
      [ $# -ge 2 ] || { usage; exit 2; }
      ROOT=$2
      shift 2
      ;;
    --local)
      MODE=local
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

case "$MODE" in
  ref)
    [ -n "$REF" ] || { usage; exit 2; }
    [ -d "$ROOT" ] || { echo "error: repository root not found: $ROOT" >&2; exit 2; }
    ;;
  local)
    [ $# -gt 0 ] || { usage; exit 2; }
    ;;
  *)
    usage
    exit 2
    ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required by fm-evidence-check.sh" >&2
  exit 2
}

exec python3 - "$MODE" "$REF" "$ROOT" "$@" <<'PY'
import hashlib
import os
import re
import subprocess
import sys

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
MARKER_SUFFIX = ".allow-identical"


def classify(basename):
    """Return (side, pair_key_suffix) for a before/after evidence filename, or None."""
    lower = basename.lower()
    if lower.startswith("before-"):
        return "before", basename[len("before-"):]
    if lower.startswith("after-"):
        return "after", basename[len("after-"):]
    match = re.match(r"^(.*)-before(\.[A-Za-z0-9]+)$", basename)
    if match:
        return "before", match.group(1) + match.group(2)
    match = re.match(r"^(.*)-after(\.[A-Za-z0-9]+)$", basename)
    if match:
        return "after", match.group(1) + match.group(2)
    return None


def is_image(path):
    return os.path.splitext(path)[1].lower() in IMAGE_EXTENSIONS


def load_ref_entries(root, ref, pathspecs):
    cmd = ["git", "-C", root, "ls-tree", "-r", ref]
    if pathspecs:
        cmd += ["--"] + list(pathspecs)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or "unknown error"
        sys.stderr.write(f"fm-evidence-check: git ls-tree failed: {detail}\n")
        sys.exit(2)
    entries = []
    for line in proc.stdout.split("\n"):
        if not line:
            continue
        meta, _, path = line.partition("\t")
        parts = meta.split()
        if len(parts) != 3 or parts[1] != "blob":
            continue
        if is_image(path):
            entries.append((path, parts[2]))
    return entries


def marker_exists_ref(root, ref, marker_path):
    proc = subprocess.run(
        ["git", "-C", root, "cat-file", "-e", f"{ref}:{marker_path}"],
        capture_output=True, check=False,
    )
    return proc.returncode == 0


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_local_entries(paths):
    files = []
    for given in paths:
        if os.path.isdir(given):
            for dirpath, _dirnames, filenames in os.walk(given):
                for name in filenames:
                    files.append(os.path.join(dirpath, name))
        elif os.path.isfile(given):
            files.append(given)
        else:
            sys.stderr.write(f"fm-evidence-check: path not found: {given}\n")
            sys.exit(2)
    return [(path, sha256_of(path)) for path in files if is_image(path)]


def marker_exists_local(marker_path):
    return os.path.isfile(marker_path)


def main():
    mode, ref, root = sys.argv[1], sys.argv[2], sys.argv[3]
    rest = sys.argv[4:]

    if mode == "ref":
        entries = load_ref_entries(root, ref, rest)
    else:
        entries = load_local_entries(rest)

    groups = {}
    for path, ident in entries:
        classified = classify(os.path.basename(path))
        if classified is None:
            continue
        side, suffix = classified
        key = (os.path.dirname(path), suffix)
        groups.setdefault(key, {"before": [], "after": []})[side].append((path, ident))

    failures = []
    opted_out = []
    pairs_checked = 0
    for _key, sides in sorted(groups.items()):
        befores = sides["before"]
        afters = sides["after"]
        if not befores or not afters:
            continue
        for before_path, before_ident in befores:
            for after_path, after_ident in afters:
                pairs_checked += 1
                if before_ident != after_ident:
                    continue
                marker_path = after_path + MARKER_SUFFIX
                allowed = (
                    marker_exists_ref(root, ref, marker_path)
                    if mode == "ref"
                    else marker_exists_local(marker_path)
                )
                (opted_out if allowed else failures).append((before_path, after_path))

    for before_path, after_path in opted_out:
        print(f"fm-evidence-check: identical-ok (opted out): {before_path} == {after_path}")

    if failures:
        for before_path, after_path in failures:
            sys.stderr.write(
                "fm-evidence-check: refused: byte-identical before/after pair: "
                f"{before_path} == {after_path}\n"
                "fm-evidence-check: if this is intentional, commit an empty marker "
                f"file: {after_path}{MARKER_SUFFIX}\n"
            )
        return 1

    print(
        f"fm-evidence-check: ok pairs_checked={pairs_checked} "
        f"identical_opted_out={len(opted_out)}"
    )
    return 0


sys.exit(main())
PY
