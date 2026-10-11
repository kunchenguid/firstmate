#!/usr/bin/env python3
"""Independent small-history and alignment oracles for teardown containment.

Executed by fm-teardown.test.sh. The slot oracle records which logical source
positions were edited; it never derives expected results from the production
matcher. The alignment oracle enumerates equal subsequences independently.
"""

import importlib.util
import itertools
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fm_containment", ROOT / "bin/fm-content-containment.py")
proof = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = proof
spec.loader.exec_module(proof)


def brute_anchors(left, right):
    alignments = []
    for size in range(min(len(left), len(right)), -1, -1):
        for lhs in itertools.combinations(range(len(left)), size):
            for rhs in itertools.combinations(range(len(right)), size):
                if [left[i] for i in lhs] == [right[j] for j in rhs]:
                    alignments.append(dict(zip(lhs, rhs)))
        if alignments:
            break
    return {i: alignments[0][i] for i in range(len(left))
            if all(i in item for item in alignments)
            and len({item[i] for item in alignments}) == 1}


def linear_contained(base, history, local, merged):
    return proof.text_contained(base, list(zip([base, *history], [*history, local])), local, merged)


class ContainmentContract(unittest.TestCase):
    def test_all_optimal_alignment_ties_against_enumerated_subsequences(self):
        strings = [list(word) for n in range(5) for word in itertools.product((b"a", b"b"), repeat=n)]
        for left, right in itertools.product(strings, repeat=2):
            self.assertEqual(proof.anchors(left, right), brute_anchors(left, right), (left, right))

    def test_independent_history_slots_with_restoration_deletion_and_upstream(self):
        # Unique untouched separators establish independently known locations.
        def render(slots):
            return b"begin\n" + b"".join(
                value + ("anchor-%d\n" % i).encode() for i, value in enumerate(slots)
            )

        base = (b"zero\n", b"zero\n", b"zero\n")
        operations = list(itertools.product(range(2), (b"zero\n", b"one\n", b"two\n", b"")))
        cases = 0
        for first, second in itertools.product(operations, repeat=2):
            states, touched = [base], set()
            for position, replacement in (first, second):
                updated = list(states[-1])
                if updated[position] != replacement:
                    touched.add(position)
                updated[position] = replacement
                states.append(tuple(updated))
            for landed_at, upstream in itertools.product(range(3), (False, True)):
                merged = list(states[landed_at])
                if upstream:
                    merged[2] = b"independent-upstream\n"
                expected = all(states[-1][slot] == merged[slot] for slot in touched)
                actual = linear_contained(render(base), [render(state) for state in states[1:]],
                                          render(states[-1]), render(merged))
                self.assertEqual(actual, expected, (first, second, landed_at, upstream))
                cases += 1
        self.assertEqual(cases, 384)

    def test_location_not_matching_text_elsewhere(self):
        base = b"A\nx\nB\nx\nC\n"
        local = b"A\ny\nB\nx\nC\n"
        wrong = b"A\nx\nB\ny\nC\n"
        self.assertFalse(linear_contained(base, [local], local, wrong))

    def test_same_file_restoration_remains_an_obligation(self):
        base = b"zero\nanchor\nzero\n"
        submitted = b"one\nanchor\none\n"
        local = b"one\nanchor\nzero\n"
        self.assertFalse(linear_contained(base, [submitted, local], local, submitted))

    def test_unlanded_deletion_and_file_boundaries(self):
        for before, after in ((b"keep\nremove\ntail\n", b"keep\ntail\n"),
                              (b"remove\ntail\n", b"tail\n"),
                              (b"keep\nremove\n", b"keep\n"),
                              (b"remove\n", b"")):
            self.assertFalse(linear_contained(before, [after], after, before))
            self.assertTrue(linear_contained(before, [after], after, after))

    def test_duplicate_line_ambiguity_never_chooses_convenient_location(self):
        before = b"same\nsame\n"
        local = b"same\n"
        self.assertFalse(linear_contained(before, [local], local, before))
        self.assertEqual(proof.anchors(list(before.splitlines()), list(local.splitlines())), {})

    def test_raw_binary_changes_are_not_rendered_text(self):
        self.assertFalse(linear_contained(b"text\0old", [b"text\0new"], b"text\0new", b"text\0old"))
        self.assertTrue(linear_contained(b"text\0old", [b"text\0new"], b"text\0new", b"text\0new"))

    def test_large_repeated_region_keeps_every_optimal_tie(self):
        repeated = [b"same\n"] * 5000
        self.assertEqual(proof.anchors(repeated + [b"tail\n"], repeated[1:] + [b"tail\n"]),
                         {5000: 4999})
        self.assertEqual(proof.anchors([b"head\n"] + repeated, [b"head\n"] + repeated[1:]),
                         {0: 0})

    def test_large_sparse_edits_keep_location_bound_obligations(self):
        base = [("line-%d\n" % n).encode() for n in range(5000)]
        local = [b"local\n", *base[1:]]
        merged = [*local[:-1], b"upstream\n"]
        self.assertTrue(linear_contained(b"".join(base), [b"".join(local)],
                                         b"".join(local), b"".join(merged)))
        later = [*local[:2500], b"unmerged\n", *local[2501:]]
        self.assertFalse(linear_contained(b"".join(base), [b"".join(local), b"".join(later)],
                                          b"".join(later), b"".join(merged)))

    def test_resource_limit_is_unknown_not_contained(self):
        old = proof.MAX_ALIGNMENT_CELLS
        try:
            proof.MAX_ALIGNMENT_CELLS = 4
            with self.assertRaises(proof.Unknown):
                proof.anchors([b"a", b"b"], [b"a", b"c"])
        finally:
            proof.MAX_ALIGNMENT_CELLS = old


if __name__ == "__main__":
    unittest.main()
