#!/usr/bin/env python3
"""Prove final local content is contained in an immutable landed Git result.

Internal teardown interface: fm-content-containment.py REPOSITORY LANDED_COMMIT.
Exit 0 means contained, 1 means a final obligation differs, and 2 means unknown.
No Git refs, index, working files, configuration, or remote are changed.

History is not reduced to its net patch. Every changed path and every text region
changed by a local parent-to-child comparison remains an obligation, even after
restoration. Merges with upstream parents compare against those parents; other
commits compare against all parents. Only anchors shared throughout that history
and unambiguously matched in the landed result may separate independent regions.
Each obligated region's final bytes must match between those same anchors.
This accepts independent upstream hunks, but never infers containment from patch
applicability, a matching occurrence elsewhere, or a partial history enumeration.

The alignment graph includes every optimal insertion/deletion alignment, not one
arbitrary diff. A line is an anchor only if every alignment matches it to the same
line. Ambiguous/overlapping regions stay together and must match in full.
Binary and structural changes require exact raw entries. Resource exhaustion,
missing objects, shallow/grafted history, or multiple merge bases mean unknown.
"""

from array import array
from dataclasses import dataclass
from functools import lru_cache
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


class Unknown(Exception):
    """Available evidence does not support a complete proof."""


# Bounds memory for one exact alignment to about 64 MiB, plus its frontier.
# Identical blobs/lines do not allocate an alignment matrix.
MAX_ALIGNMENT_CELLS = 16_000_000
SHA = re.compile(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


def anchors(base, value):
    """Return base-line -> value-line matches forced by all optimal alignments.

    Equal-line edges and optimal insertion/deletion edges form a DAG inside an
    edit-distance band. A band is complete only when its width covers the total
    edit distance, hence every optimal path. Visit that DAG retaining every tie,
    including deletion or insertion ties on equal lines. An anchor may neither
    be deleted on any path nor match multiple occurrences.
    """
    if base == value:
        return dict(enumerate(range(len(base))))
    n, m = len(base), len(value)
    width = max(1, abs(n - m))
    unreachable = n + m + 1
    while True:
        cells = sum(min(m, i + width) - max(0, i - width) + 1 for i in range(n + 1))
        if cells > MAX_ALIGNMENT_CELLS:
            raise Unknown("text alignment exceeds the exact-proof memory bound")
        starts = [max(0, i - width) for i in range(n + 1)]
        stops = [min(m, i + width) + 1 for i in range(n + 1)]
        scores = [array("I", [unreachable]) * (stop - start) for start, stop in zip(starts, stops)]

        def distance(i, j):
            if i > n or not starts[i] <= j < stops[i]:
                return unreachable
            return scores[i][j - starts[i]]

        for i in range(n, -1, -1):
            row = scores[i]
            for j in range(stops[i] - 1, starts[i] - 1, -1):
                if i == n and j == m:
                    best = 0
                else:
                    best = min(unreachable, 1 + distance(i + 1, j), 1 + distance(i, j + 1))
                    if i < n and j < m and base[i] == value[j]:
                        best = min(best, distance(i + 1, j + 1))
                row[j - starts[i]] = best
        if distance(0, 0) <= width:
            break
        scores.clear()
        width = min(n + m, width * 2)
    matches = [set() for _ in base]
    deleted = set()
    # A row frontier avoids retaining a Python object for every visited cell.
    frontier = {0}
    for i in range(n + 1):
        following = set()
        for j in range(starts[i], stops[i]):
            if j not in frontier:
                continue
            score = distance(i, j)
            if j < m and 1 + distance(i, j + 1) == score:
                frontier.add(j + 1)
            if i < n:
                if 1 + distance(i + 1, j) == score:
                    deleted.add(i)
                    following.add(j)
                if j < m and base[i] == value[j] and distance(i + 1, j + 1) == score:
                    matches[i].add(j)
                    following.add(j + 1)
        frontier = following
    return {i: next(iter(positions)) for i, positions in enumerate(matches)
            if i not in deleted and len(positions) == 1}


def text_contained(base_bytes, comparisons, local_bytes, merged_bytes):
    """Compare final obligations between history-stable, location-bound anchors.

    A segment is an obligation if any local parent-to-child comparison changes
    it. Compare its final local and merged bytes, not intermediate values.
    Include virtual file boundaries so empty/deleted regions and insertions at
    either end cannot disappear from the proof.
    """
    if local_bytes == merged_bytes:
        return True
    versions = list(dict.fromkeys([content for pair in comparisons for content in pair] + [local_bytes]))
    if any(b"\0" in content for content in [base_bytes, merged_bytes, *versions]):
        return False
    base = base_bytes.splitlines(keepends=True)
    history = [content.splitlines(keepends=True) for content in versions]
    local = local_bytes.splitlines(keepends=True)
    merged = merged_bytes.splitlines(keepends=True)
    history_maps = [anchors(base, version) for version in history]
    local_map = history_maps[versions.index(local_bytes)]
    version_indexes = {content: index for index, content in enumerate(versions)}
    edges = [(version_indexes[before], version_indexes[after]) for before, after in comparisons]
    merged_map = anchors(base, merged)
    stable = set(merged_map)
    for mapping in history_maps:
        stable.intersection_update(mapping)
    boundaries = [-1, *sorted(stable), len(base)]

    def position(mapping, sequence, index):
        if index == -1:
            return -1
        if index == len(base):
            return len(sequence)
        return mapping[index]

    for left, right in zip(boundaries, boundaries[1:]):
        segments = [version[position(mapping, version, left) + 1:position(mapping, version, right)]
                    for version, mapping in zip(history, history_maps)]
        touched = any(segments[before] != segments[after] for before, after in edges)
        if touched:
            final_local = local[position(local_map, local, left) + 1:position(local_map, local, right)]
            final_merged = merged[position(merged_map, merged, left) + 1:position(merged_map, merged, right)]
            if final_local != final_merged:
                return False
    return True


@dataclass(frozen=True)
class Entry:
    mode: int
    oid: bytes


class Repository:
    def __init__(self, directory):
        self.directory = directory

    def git(self, *args):
        result = subprocess.run(
            ["git", "--no-replace-objects", "-C", self.directory, *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0"},
        )
        if result.returncode:
            raise Unknown("Git could not read complete containment evidence")
        return result.stdout

    @staticmethod
    def oid(value):
        if not SHA.fullmatch(value):
            raise Unknown("invalid immutable object identity")
        return value

    @lru_cache(maxsize=4096)
    def object(self, kind, oid):
        self.oid(oid)
        data = self.git("cat-file", kind, oid.decode("ascii"))
        digest = hashlib.new("sha1" if len(oid) == 40 else "sha256")
        digest.update(kind.encode("ascii") + b" " + str(len(data)).encode("ascii") + b"\0" + data)
        if digest.hexdigest().encode("ascii") != oid:
            raise Unknown("Git object content does not match its identity")
        return data

    @lru_cache(maxsize=2048)
    def commit(self, oid):
        header = self.object("commit", oid).split(b"\n\n", 1)[0].splitlines()
        if not header or not header[0].startswith(b"tree "):
            raise Unknown("commit has no tree")
        tree = self.oid(header[0][5:])
        parents = [self.oid(line[7:]) for line in header[1:] if line.startswith(b"parent ")]
        return tree, parents

    @lru_cache(maxsize=4096)
    def tree(self, oid):
        data = self.object("tree", oid)
        width = len(oid) // 2
        result, offset = {}, 0
        while offset < len(data):
            space = data.find(b" ", offset)
            zero = data.find(b"\0", space + 1)
            if space < offset or zero < space or zero + 1 + width > len(data):
                raise Unknown("truncated tree record")
            mode = int(data[offset:space], 8)
            name = data[space + 1:zero]
            child = data[zero + 1:zero + 1 + width].hex().encode("ascii")
            offset = zero + 1 + width
            if not name or name in (b".", b"..") or b"/" in name:
                raise Unknown("invalid tree path")
            if mode == 0o40000:
                entries = {name + b"/" + path: value for path, value in self.tree(child).items()}
            elif mode in (0o100644, 0o100755, 0o120000, 0o160000):
                entries = {name: Entry(mode, child)}
            else:
                raise Unknown("unsupported tree entry")
            if result.keys() & entries.keys():
                raise Unknown("duplicate tree path")
            result.update(entries)
        return result

    def contents(self, entry):
        if entry is None:
            return b""
        if entry.mode == 0o160000:
            # A gitlink is an exact structural obligation, not a local blob.
            return entry.oid
        return self.object("blob", entry.oid)

    def contains(self, target):
        if self.git("rev-parse", "--is-shallow-repository").strip() != b"false":
            raise Unknown("shallow history cannot establish complete local obligations")
        graft = self.git("rev-parse", "--git-path", "info/grafts").strip()
        graft_path = Path(os.fsdecode(graft))
        if not graft_path.is_absolute():
            graft_path = Path(self.directory) / graft_path
        if graft_path.exists() and graft_path.stat().st_size:
            raise Unknown("grafted history cannot establish immutable ancestry")
        local = self.oid(self.git("rev-parse", "--verify", "HEAD^{commit}").strip())
        merged = self.oid(self.git("rev-parse", "--verify", "--end-of-options", target + "^{commit}").strip())
        bases = self.git("merge-base", "--all", local.decode(), merged.decode()).splitlines()
        if len(bases) != 1:
            raise Unknown("a unique common base could not be established")
        base = self.oid(bases[0])
        commits = [self.oid(oid) for oid in self.git("rev-list", "--reverse", base.decode() + ".." + local.decode()).splitlines()]
        base_tree = self.tree(self.commit(base)[0])
        local_tree = self.tree(self.commit(local)[0])
        merged_tree = self.tree(self.commit(merged)[0])
        histories, comparisons, paths = [], [], set()
        local_commits = set(commits)
        for oid in commits:
            root, parents = self.commit(oid)
            current = self.tree(root)
            if not parents:
                raise Unknown("local history has an unbound root")
            upstream_parents = [parent for parent in parents if parent not in local_commits]
            for parent in parents:
                previous = self.tree(self.commit(parent)[0])
                histories.append(previous)
                if upstream_parents and parent not in upstream_parents:
                    continue
                comparisons.append((previous, current))
                paths.update(path for path in current.keys() | previous.keys()
                             if current.get(path) != previous.get(path))
            histories.append(current)
        # Read every required raw blob before accepting a result, including
        # superseded versions, so later equality cannot mask missing history.
        for tree in [base_tree, local_tree, merged_tree, *histories]:
            for path in paths:
                self.contents(tree.get(path))
        for path in paths:
            before, final, landed = base_tree.get(path), local_tree.get(path), merged_tree.get(path)
            if final == landed:
                continue
            if (before is None or final is None or landed is None
                    or any(entry.mode not in (0o100644, 0o100755) for entry in (before, final, landed))
                    or final.mode != landed.mode):
                return False
            versions = [tree.get(path) for tree in histories]
            if any(entry is None or entry.mode not in (0o100644, 0o100755) for entry in versions):
                # File creation/deletion/type transitions require exact final
                # entries rather than an invented text-line correspondence.
                return False
            if not text_contained(self.contents(before),
                                  [(self.contents(previous.get(path)), self.contents(current.get(path)))
                                   for previous, current in comparisons],
                                  self.contents(final), self.contents(landed)):
                return False
        # Same immutable input must still be selected at the caller boundary.
        if self.git("rev-parse", "--verify", "HEAD^{commit}").strip() != local:
            raise Unknown("local head changed during containment proof")
        return True


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return 0 if Repository(sys.argv[1]).contains(sys.argv[2]) else 1
    except (Unknown, OSError, ValueError, RecursionError, MemoryError) as exc:
        print("containment unknown: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
