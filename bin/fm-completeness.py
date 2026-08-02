#!/usr/bin/env python3
"""Formal completeness gate for firstmate task-lifecycle decisions.

Firstmate's "is this task done / safe to tear down / clear to merge?" calls are
really invariants (AGENTS.md prime directives #2 and #3). This turns them into a
formal rule set checked by Z3: firstmate proposes a completion claim with the
observed facts, and the solver PROVES it either SAT (consistent with every
invariant) or UNSAT (provably premature, with the violated rule named). Hard
rules gate; soft rules score (never block).

The only dependency is `z3-solver` (public PyPI) — there is no other library to
install. The rules are DATA, not code: they load from fm-completeness.rules.json
(or $FM_COMPLETENESS_RULES). This module is a small self-contained shim that
compiles that data into a Z3 model and runs the check.

Encoding: each axis is a Z3 EnumSort variable. A hard rule compiles to
`Implies(when, require AND not-forbid)`. A concrete claim is verified by asking,
per rule, whether (facts AND rule) is satisfiable — UNSAT means that rule is
violated by the facts. `prove_consistency` checks the whole hard rule set is
satisfiable over free axes (a contradiction there is a bug in the directives,
not the task). Soft rules score deterministically over the concrete metadata.

I/O: reads one JSON object of facts on stdin, e.g.
    {"name": "fix-x", "kind": "ship", "landed": "none",
     "worktree": "holds_unlanded_work", "mode": "strict",
     "metadata": {"backlog_recorded": true}}
`mode` is "strict" (default, hard invariants only) or "graded" (also scores soft
rules). All other top-level keys except name/mode/metadata are axis values.

Prints a JSON result on stdout. Exit 0 if SAT, 2 if UNSAT, 3 on a tooling error
(so the bash wrapper can fail-open and defer to its own checks), 64 when the
facts themselves are invalid (a typo, not a pass - callers must treat it as
blocking, never fail-open).
"""
from __future__ import annotations

import json
import os
import sys

EXIT_SAT = 0
EXIT_UNSAT = 2
EXIT_ERROR = 3
EXIT_BAD_FACTS = 64


class RulesError(Exception):
    """The rules file itself is broken (a tooling error, not a verdict)."""


def _default_rules_path() -> str:
    env = os.environ.get("FM_COMPLETENESS_RULES")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fm-completeness.rules.json")


def _build_axes(z3, axes_spec):
    """Compile each axis into a Z3 EnumSort plus its value-constant map."""
    consts = {}   # axis -> {value_str: z3 const}
    variables = {}  # axis -> z3 Const (the proposed value of that axis)
    for axis, values in axes_spec.items():
        values = list(values)
        _sort, members = z3.EnumSort(axis, values)
        consts[axis] = dict(zip(values, members))
        variables[axis] = z3.Const(axis + "__proposed", _sort)
    return consts, variables


def _rule_constraint(z3, rule, consts, variables):
    """Compile one hard rule to Implies(when, require AND not-forbid)."""
    when = rule.get("when", {})
    require = rule.get("require", {})
    forbid = rule.get("forbid", {})

    antecedent = [variables[k] == consts[k][v] for k, v in when.items()]
    consequent = [variables[k] == consts[k][v] for k, v in require.items()]
    consequent += [variables[k] != consts[k][v] for k, v in forbid.items()]

    body = z3.And(*consequent) if consequent else z3.BoolVal(True)
    if antecedent:
        return z3.Implies(z3.And(*antecedent), body)
    return body


def _verify_hard(z3, spec, fact_axes, consts, variables):
    """Return the list of hard rules whose constraint is violated by the facts.

    A rule is violated iff (facts AND rule) is UNSAT — i.e. no world with these
    facts can also satisfy the rule. Checking per rule names every violation,
    not just one minimal unsat core.
    """
    fact_asserts = [variables[k] == consts[k][v] for k, v in fact_axes.items()]
    violated = []
    for rule in spec.get("hard_rules", []):
        solver = z3.Solver()
        for assertion in fact_asserts:
            solver.add(assertion)
        solver.add(_rule_constraint(z3, rule, consts, variables))
        if solver.check() == z3.unsat:
            violated.append(rule)
    return violated


def _score_soft(spec, fact_axes, metadata):
    """Deterministic weighted compliance over concrete metadata (never gates)."""
    total = 0
    satisfied = 0
    unmet = []
    for rule in spec.get("soft_rules", []):
        when = rule.get("when", {})
        if any(fact_axes.get(k) != v for k, v in when.items()):
            continue  # rule does not apply to this proposal
        weight = int(rule.get("weight", 1))
        total += weight
        key = rule.get("require_meta")
        if key is not None and metadata.get(key):
            satisfied += weight
        else:
            unmet.append(rule["name"])
    compliance = 1.0 if total == 0 else satisfied / total
    return compliance, unmet


def prove_consistency(z3, spec, consts, variables) -> bool:
    """True iff the whole hard rule set is satisfiable over free axis values."""
    solver = z3.Solver()
    for rule in spec.get("hard_rules", []):
        solver.add(_rule_constraint(z3, rule, consts, variables))
    return solver.check() == z3.sat


def check(spec: dict, facts: dict) -> dict:
    import z3  # public PyPI z3-solver; absence -> ImportError -> caller fails open

    mode = facts.get("mode", "strict")
    metadata = facts.get("metadata", {}) or {}
    declared = spec.get("axes", {})
    fact_axes = {k: v for k, v in facts.items()
                 if k not in ("name", "mode", "metadata") and k in declared}

    # A fact whose value the data file never declared is a typo, not a pass.
    for axis, value in fact_axes.items():
        if value not in declared[axis]:
            raise ValueError(
                "fact %s=%r is not a declared value of axis %s (%s)"
                % (axis, value, axis, ", ".join(declared[axis])))

    consts, variables = _build_axes(z3, declared)

    if not prove_consistency(z3, spec, consts, variables):
        raise RulesError(
            "hard rule set is unsatisfiable over free axes; the rules file "
            "contradicts itself (a bug in the directives, not the task)")

    violated = _verify_hard(z3, spec, fact_axes, consts, variables)
    sat = not violated

    if mode == "graded":
        compliance, unmet = _score_soft(spec, fact_axes, metadata)
    else:
        compliance, unmet = 1.0, []

    if sat:
        reason = "consistent with every invariant"
    else:
        reason = "; ".join("[%s] %s" % (r["name"], r["reason"]) for r in violated)

    return {
        "sat": bool(sat),
        "reason": reason,
        "violated_rules": [r["name"] for r in violated],
        "counterexample": None,
        "compliance": compliance,
        "unmet_soft": unmet,
        "mode": mode,
    }


def main() -> int:
    try:
        raw = sys.stdin.read()
        facts = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError) as exc:
        print(json.dumps({"error": "bad facts JSON: %s" % exc}), file=sys.stderr)
        return EXIT_ERROR

    rules_path = _default_rules_path()
    try:
        with open(rules_path, encoding="utf-8") as handle:
            spec = json.load(handle)
    except (OSError, ValueError) as exc:
        print(json.dumps({"error": "cannot read rules file %s: %s"
                          % (rules_path, exc)}), file=sys.stderr)
        return EXIT_ERROR
    if not isinstance(spec, dict):
        print(json.dumps({"error": "rules file %s is not a JSON object"
                          % rules_path}), file=sys.stderr)
        return EXIT_ERROR

    try:
        out = check(spec, facts)
    except ImportError as exc:
        print(json.dumps({"error": "z3-solver not importable: %s" % exc}),
              file=sys.stderr)
        return EXIT_ERROR
    except ValueError as exc:
        print(json.dumps({"error": "invalid facts: %s" % exc}),
              file=sys.stderr)
        return EXIT_BAD_FACTS
    except (RulesError, KeyError, TypeError, AttributeError) as exc:
        print(json.dumps({"error": "broken rules file %s: %s"
                          % (rules_path, exc)}), file=sys.stderr)
        return EXIT_ERROR

    print(json.dumps(out))
    return EXIT_SAT if out["sat"] else EXIT_UNSAT


if __name__ == "__main__":
    sys.exit(main())
