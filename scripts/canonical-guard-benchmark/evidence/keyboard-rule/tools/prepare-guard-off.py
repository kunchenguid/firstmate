#!/usr/bin/env python3
"""Turn an installed GUARD-OFF template into the arm that has no keyboard rule.

`benchmark.py init` already deletes the pre-push command block that runs the
project's boundary check, which is the whole arm difference for a rule the
project only enforces at push. This rule also ships a blocking CI step and a
rule table a candidate can read and run by hand, so the GUARD-OFF arm drops the
rule entry and both CI steps as well, and hides all three from the candidate's
working tree the same way `init` hides the deleted hook block.

Prints the exact unified diff it applied, for the frozen plan to record.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

RULES = "packages/frontend/scripts/canonical/canonical-rules.ts"
WORKFLOW = ".github/workflows/ci.yml"
STEP_START = re.compile(r"^\s*- (?:name|uses):")


def git(repo: pathlib.Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def without_rule(text: str, rule_id: str) -> str:
    lines = text.splitlines(keepends=True)
    marker = next((index for index, line in enumerate(lines) if re.match(rf"\s*id: '{re.escape(rule_id)}',\s*$", line)), None)
    if marker is None:
        raise SystemExit(f"{RULES} has no rule entry with id {rule_id}")
    start = next(index for index in range(marker, -1, -1) if lines[index].rstrip("\n") == "  {")
    depth = 0
    for end in range(start, len(lines)):
        depth += lines[end].count("{") - lines[end].count("}")
        if depth == 0:
            return "".join(lines[:start] + lines[end + 1 :])
    raise SystemExit(f"{RULES} rule entry for {rule_id} is unbalanced")


def without_ci_steps(text: str, command: str) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    removed = 0
    for index in range(len(lines) - 1, -1, -1):
        if lines[index].strip() != f"run: {command}":
            continue
        start = next(back for back in range(index, -1, -1) if STEP_START.match(lines[back]))
        while start > 0 and lines[start - 1].strip().startswith("#"):
            start -= 1
        while start > 0 and not lines[start - 1].strip():
            start -= 1
            break
        lines[start : index + 1] = []
        removed += 1
    if removed == 0:
        raise SystemExit(f"{WORKFLOW} has no step running {command}")
    return "".join(lines), removed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True, help="the installed GUARD-OFF template")
    parser.add_argument("--rule-id", default="keyboard-listener")
    parser.add_argument("--command", default="pnpm check:canonical")
    arguments = parser.parse_args()

    template = pathlib.Path(arguments.template).resolve()
    if not (template / ".git").exists():
        raise SystemExit(f"not a checkout: {template}")

    rules = template / RULES
    workflow = template / WORKFLOW
    rules.write_text(without_rule(rules.read_text(), arguments.rule_id))
    updated, removed_steps = without_ci_steps(workflow.read_text(), arguments.command)
    workflow.write_text(updated)

    for path in (RULES, WORKFLOW):
        if arguments.rule_id in (template / path).read_text() and path == RULES:
            raise SystemExit(f"{path} still names {arguments.rule_id}")
    if arguments.command in workflow.read_text():
        raise SystemExit(f"{WORKFLOW} still runs {arguments.command}")

    diff = git(template, "diff", "--", RULES, WORKFLOW)
    git(template, "update-index", "--assume-unchanged", "--", RULES, WORKFLOW)
    exposed = git(template, "status", "--porcelain")
    if exposed.strip():
        raise SystemExit(f"GUARD-OFF template exposes its arm difference:\n{exposed}")

    loads = subprocess.run(
        ["node", "packages/frontend/scripts/canonical/check-canonical.ts", "--stats"],
        cwd=template, text=True, capture_output=True,
    )
    if loads.returncode != 0:
        raise SystemExit(f"the edited rule table no longer loads:\n{loads.stdout}\n{loads.stderr}")

    print(json.dumps({
        "template": str(template), "rule_removed": arguments.rule_id,
        "ci_steps_removed": removed_steps, "diff": diff,
        "rule_table_loads": loads.stdout.strip(),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
