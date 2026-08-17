#!/usr/bin/env bash
# fm-worktree-unique-content.sh - prove whether a worktree holds content that
# exists nowhere else, instead of merely asking whether it is dirty.
#
# `git status` dirtiness means "index or working tree differs from HEAD". The
# property destructive cleanup actually needs is "this worktree holds content
# that exists nowhere else". The two invert when a branch ref is rewritten
# beneath a live worktree (a bare ref write with no checkout, e.g. a pipeline
# returning a rebased branch): index and working tree stay at the pre-rewrite
# state, so status presents already-landed work as staged deletions and
# pre-merge line versions as insertions. Discarding that state loses nothing,
# while committing or "preserving" it would delete landed work.
#
# Decision, per differing path from `git status --porcelain=v2 -z -uall`:
#   - a deletion (staged or unstaged) holds no content and never blocks;
#   - staged content is the index blob, working-tree and untracked content is
#     hashed read-only (`git hash-object` without -w; symlinks hash their link
#     text); the zero-byte blob is never unique because empty content is not
#     work;
#   - every such blob must be REACHABLE from a surviving ref: any
#     refs/heads/*, refs/remotes/*, or refs/tags/* EXCEPT the worktree's own
#     checked-out branch, because teardown deletes that branch, so it cannot
#     prove the content survives. Reachability is collected from one
#     `git log -m --no-renames --raw` walk of those refs filtered to the differing
#     paths, so both sides of every historical change of those paths count.
#   - anything else - an unmerged entry, a submodule entry, a staged or
#     unstaged mode change, an unparseable record, any git error - is
#     unprovable and refuses.
#
# The classifier can only ever NARROW a caller's dirty refusal: exit 0 is a
# positive proof and every other outcome (including this script being absent)
# leaves the caller's refusal standing, so no failure mode weakens it.
# tests/fm-worktree-unique-content.test.sh holds the mutation proof: deleting,
# bypassing, weakening, or force-passing the predicate is caught by its oracle.
#
# Callers: bin/fm-teardown.sh consults it before refusing a dirty ship
# worktree; any preflight that would discard a worktree state may call it the
# same way.
#
# Usage: fm-worktree-unique-content.sh <worktree> [--excluded-untracked-regex <re>]
#   --excluded-untracked-regex  Python/ERE-compatible regex matched against
#                               repo-relative untracked paths; matches are the
#                               caller's declared-benign files (e.g. harness
#                               droppings) and are skipped. Tracked entries are
#                               never excluded.
# Exit codes:
#   0  proven: every differing path holds only reachable (or empty) content
#   1  the worktree holds, or may hold, content that exists nowhere else;
#      also every error and unprovable state
#   2  usage error (including an unparseable exclusion regex)
# Stdout: one classification line per differing path, then a final verdict
# line. Stderr: errors and refusal reasons.
set -eu

usage() {
  printf 'usage: %s <worktree> [--excluded-untracked-regex <re>]\n' "$(basename "$0")"
}

WT=
EXCLUDE_RE=
while [ $# -gt 0 ]; do
  case "$1" in
    --excluded-untracked-regex)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      EXCLUDE_RE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'error: unknown flag %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$WT" ]; then usage >&2; exit 2; fi
      WT=$1
      shift
      ;;
  esac
done
[ -n "$WT" ] || { usage >&2; exit 2; }
if [ ! -d "$WT" ]; then
  printf 'fm-worktree-unique-content: not a directory: %s\n' "$WT" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-worktree-unique-content: python3 is required and missing\n' >&2
  exit 1
fi

exec python3 - "$WT" "$EXCLUDE_RE" <<'PY'
import os
import re
import stat
import subprocess
import sys

WT = sys.argv[1]
EXCLUDE_RE_RAW = sys.argv[2] if len(sys.argv) > 2 else ""

EXCLUDE_RE = None
if EXCLUDE_RE_RAW:
    try:
        EXCLUDE_RE = re.compile(EXCLUDE_RE_RAW)
    except re.error as exc:
        print(f"fm-worktree-unique-content: invalid --excluded-untracked-regex: {exc}",
              file=sys.stderr)
        sys.exit(2)


def refuse(msg):
    print(f"fm-worktree-unique-content: {msg}", file=sys.stderr)
    sys.exit(1)


def printable(path_bytes):
    text = path_bytes.decode("utf-8", "backslashreplace")
    return "".join(ch if ch.isprintable() else ascii(ch)[1:-1] for ch in text)


def git(*args, data=None):
    try:
        proc = subprocess.run(
            ["git", "-C", WT, *args],
            input=data,
            capture_output=True,
        )
    except OSError as exc:
        refuse(f"cannot run git: {exc}")
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip()
        shown = " ".join(a if isinstance(a, str) else printable(a) for a in args[:4])
        refuse(f"git {shown} failed: {err or proc.returncode}")
    return proc.stdout


def is_zero(oid):
    return set(oid) == {"0"}


TOP = git("rev-parse", "--show-toplevel").rstrip(b"\n")
EMPTY_BLOB = git("hash-object", "-t", "blob", "--stdin", data=b"").decode().strip()

# --- collect the differing paths and the blobs each one holds ---------------

status = git("status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames")

needed = []          # (path_bytes, oid_str) - blobs that must be proven reachable
hash_worktree = []   # path_bytes whose on-disk content still needs hashing
skipped = []         # (label, path_bytes) - entries proven to hold nothing

for tok in status.split(b"\0"):
    if not tok:
        continue
    if tok.startswith(b"1 "):
        parts = tok.split(b" ", 8)
        if len(parts) != 9:
            refuse("unparseable status record")
        _, xy, sub, m_head, m_index, m_wt, h_head, h_index, path = parts
        if not sub.startswith(b"N"):
            refuse(f"submodule state at '{printable(path)}' cannot be proven")
        try:
            y = chr(xy[1])
        except IndexError:
            refuse("unparseable status record")
        h_head = h_head.decode()
        h_index = h_index.decode()
        if not is_zero(h_head) and not is_zero(h_index) and m_head != m_index:
            refuse(f"staged mode change at '{printable(path)}' is not content and cannot be proven")
        if not is_zero(h_index) and h_index != h_head:
            needed.append((path, h_index))
        elif h_index != h_head:
            skipped.append(("deletion", path))
        if y in ("M", "T", "A"):
            if not is_zero(m_index.decode()) and not is_zero(m_wt.decode()) and m_index != m_wt:
                refuse(f"working-tree mode change at '{printable(path)}' cannot be proven")
            hash_worktree.append(path)
        elif y == "D":
            skipped.append(("deletion", path))
        elif y != ".":
            refuse(f"unrecognized working-tree state '{y}' at '{printable(path)}'")
    elif tok.startswith(b"? "):
        path = tok[2:]
        if EXCLUDE_RE and EXCLUDE_RE.search(path.decode("utf-8", "surrogateescape")):
            skipped.append(("excluded-untracked", path))
            continue
        hash_worktree.append(path)
    elif tok.startswith(b"! ") or tok.startswith(b"# "):
        continue
    elif tok.startswith(b"2 ") or tok.startswith(b"u "):
        refuse("a rename or unmerged entry cannot be proven")
    else:
        refuse("unrecognized status record")

for path in hash_worktree:
    full = os.path.join(TOP, path)
    try:
        st = os.lstat(full)
    except OSError as exc:
        refuse(f"cannot inspect '{printable(path)}': {exc}")
    if stat.S_ISLNK(st.st_mode):
        target = os.readlink(full)
        if isinstance(target, str):
            target = os.fsencode(target)
        oid = git("hash-object", "-t", "blob", "--stdin", data=target).decode().strip()
    elif stat.S_ISREG(st.st_mode):
        oid = git("hash-object", "-t", "blob", "--", path).decode().strip()
    else:
        refuse(f"'{printable(path)}' is neither a regular file nor a symlink")
    needed.append((path, oid))

# --- collect every blob those paths ever held on a surviving ref ------------

head_branch = None
proc = subprocess.run(
    ["git", "-C", WT, "symbolic-ref", "--quiet", "HEAD"],
    capture_output=True,
)
if proc.returncode == 0:
    head_branch = proc.stdout.strip()

anchors = []
for ref in git("for-each-ref", "--format=%(refname)",
               "refs/heads", "refs/remotes", "refs/tags").splitlines():
    if ref and ref != head_branch:
        anchors.append(ref)

reachable = set()
if needed and anchors:
    pathspecs = [b":(literal)" + p for p in sorted({p for p, _ in needed})]
    walk = git("log", "-m", "--no-renames", "--raw", "--no-abbrev", "-z",
               "--format=", *anchors, "--", *pathspecs)
    toks = walk.split(b"\0")
    i = 0
    while i < len(toks):
        meta = toks[i].lstrip(b"\n")
        if not meta:
            i += 1
            continue
        if not meta.startswith(b":"):
            refuse("unexpected token in the history walk")
        fields = meta.split(b" ")
        if len(fields) != 5:
            refuse("unparseable raw record in the history walk")
        mode_old, mode_new = fields[0][1:], fields[1]
        oid_old, oid_new = fields[2].decode(), fields[3].decode()
        if mode_old != b"160000" and not is_zero(oid_old):
            reachable.add(oid_old)
        if mode_new != b"160000" and not is_zero(oid_new):
            reachable.add(oid_new)
        i += 2  # the following token is the path; never interpreted

# --- verdict ----------------------------------------------------------------

# MUTATION:predicate-begin
def unreachable_blobs(needed, reachable):
    unique = []
    for path, oid in needed:
        if oid == EMPTY_BLOB:
            continue
        if oid in reachable:
            continue
        unique.append((path, oid))
    return unique
# MUTATION:predicate-end


unique = unreachable_blobs(needed, reachable)  # MUTATION:call-site

for label, path in skipped:
    print(f"{label} - {printable(path)}")
unique_set = {(p, o) for p, o in unique}
for path, oid in needed:
    verdict = "unique" if (path, oid) in unique_set else "reachable"
    print(f"{verdict} {oid} {printable(path)}")

if unique:  # MUTATION:verdict
    print(f"verdict: unique-content paths={len(needed) + len(skipped)} unique={len(unique)}")
    for path, oid in unique:
        print(f"fm-worktree-unique-content: '{printable(path)}' holds content "
              f"({oid}) reachable from no surviving ref", file=sys.stderr)
    sys.exit(1)

print(f"verdict: no-unique-content paths={len(needed) + len(skipped)}")
sys.exit(0)
PY
