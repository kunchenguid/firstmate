#!/usr/bin/env python3
"""The ONE derivation of the FM_AZURE_* names a cloud placement must persist.

WHY THIS FILE EXISTS. `SPAWN_CLOUD_ENV_ALLOWLIST` in bin/fm-spawn.sh is the set
of variables written into `state/<id>.cloud-env`, which the compartment and
crewmate monitors source in a subshell for every lifecycle call they make. Those
monitors run in Herdr panes whose environment is CLOSED: they inherit nothing
from the operator's shell, so a name missing from that file is unreachable in
production no matter what the operator exported.

The names that file must carry are decided somewhere else entirely - in the code
that READS them on the far side of the pane boundary. Before this module the two
sides learned the set independently, and they drifted: the compartment-child
lane could never create its worker at all, because bin/fm-azure-pilot.sh refuses
`worker-create` without FM_AZURE_TENANT_ID (and six more names) that the
allowlist did not carry. Every hermetic test missed it, because the tests drive
a fixture provider that never shells out to the pilot.

So: this module derives the required set FROM THE READERS, mechanically. The
allowlist stays an explicit literal in bin/fm-spawn.sh (an operator can audit one
line without running anything), and tests/fm-spawn-cloud.test.sh asserts the
PERSISTED FILE against this derivation, so a name added to a reader without
being added to the allowlist goes red.

Regenerate the allowlist literal with:

    bin/fm-cloud-env-contract.py --allowlist

Usage:
  fm-cloud-env-contract.py              one required name per line
  fm-cloud-env-contract.py --allowlist  one space-joined line for bin/fm-spawn.sh
  fm-cloud-env-contract.py --explain    each name with the readers that need it
"""

from __future__ import annotations

import ast
import io
import pathlib
import re
import sys
import tokenize

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The readers on the far side of the closed pane. Every FM_AZURE_* name any of
# them takes from the environment is a name the persisted file has to be able to
# carry, because the compartment-child lane reaches all three from the monitor:
# fm-spawn.sh -> fm-worker-lifecycle.sh -> fm-worker-lifecycle.py ->
# fm-azure-worker-provider.py -> fm-azure-pilot.sh (worker-create). The pilot is
# the one that was missed: it is a SUBPROCESS of the provider, so a grep of the
# provider alone never saw it.
READERS = (
    "bin/fm-azure-pilot.sh",
    "bin/fm-azure-worker-provider.py",
    "bin/fm-worker-lifecycle.py",
    # In the chain: bin/fm-spawn.sh invokes it as the lifecycle entrypoint. All
    # 16 of its FM_AZURE_ names sit in its header documentation and are covered
    # by the readers above, so it adds nothing to the set - but it is scanned,
    # not exempted, so the day it grows a real read the contract sees it.
    "bin/fm-worker-lifecycle.sh",
)

# Names the provider SUPPLIES to the pilot itself, per placement, in
# run_pilot_create's env.update. Persisting an operator's copy of these would be
# inert at best and a stale override at worst, so they are subtracted - and they
# are read out of that call rather than listed here, so the subtraction cannot
# drift from it either.
SUPPLIER = "bin/fm-azure-worker-provider.py"

# Reviewed exclusions: a FM_AZURE_* name a reader takes from the environment that
# must still NEVER be written to disk, because its VALUE is a credential (or
# names a file holding one). One entry per name, reason inline.
#
# THIS TUPLE IS THE LEVER THAT KEEPS A NAME OUT. The scan is a regex and cannot
# tell a read from a mention, so code_text strips comments first - but that is a
# reduction of the hazard, not its removal: a trailing shell comment still
# counts, and a reader that genuinely reads a credential-valued name would pull
# it in legitimately. When the guarding test demands such a name be reachable
# from disk, the correct answer is an entry HERE, not a new allowlist entry,
# which is why that test names this tuple in its failure message and asserts the
# persisted set EQUALS the contract rather than merely contains it.
#
# Empty today: no name any of the READERS currently takes is secret-bearing.
# That is a fact about today's readers, NOT a property of the scan. A comment
# naming a future secret-bearing variable would be enough to change that, and
# this tuple is where the answer goes when it does.
SECRET_BEARING_EXCLUSIONS: tuple[str, ...] = ()

NAME = re.compile(r"FM_AZURE_[A-Z0-9_]+")


class ContractError(RuntimeError):
    pass


def read(relative: str) -> str:
    path = ROOT / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError("reader {} is unreadable: {}".format(relative, exc))


def code_text(relative: str, text: str) -> str:
    """The reader's source with its `#` COMMENTS removed, where that is safe.

    The scan is a regex over source text and cannot tell a read from a mention,
    so without this a bare `# see FM_AZURE_CLIENT_SECRET` inside a reader would
    pull that name into the contract and the guarding test would then demand it
    be reachable from disk. Steering a developer toward persisting a credential
    is the worst thing this module could do.

    WHAT THIS ACTUALLY DOES, precisely, because overstating it is the exact
    mistake this module exists to catch:

      - Python is tokenized, and dropping COMMENT tokens is exact FOR `#`. It
        is not a claim about mentions in general: a name inside a docstring or
        any other string literal is still scanned and still enters the contract.
        Docstrings are the natural place to document environment variables, so
        that is a live case, not a corner. It over-includes, which is the safe
        direction, and SECRET_BEARING_EXCLUSIONS is the answer when it matters.

      - Shell is NOT stripped at all, deliberately. A `#` in shell is only
        sometimes a comment: inside a multi-line double-quoted string, or in an
        unquoted heredoc body, a line beginning `#$VAR` genuinely expands, and
        the obvious `line.lstrip().startswith("#")` filter drops it. That is an
        UNDER-include, the one direction that silently loses a real name and
        recreates the outage this module exists to prevent. No cheap shell parse
        tells the cases apart, so the scan does not try: shell comments count as
        reads. Costs a spurious contract entry at worst; the union is unchanged
        by this choice today.
    """
    if not relative.endswith(".py"):
        return text
    try:
        return "\n".join(
            token.string
            for token in tokenize.generate_tokens(io.StringIO(text).readline)
            if token.type != tokenize.COMMENT
        )
    except (tokenize.TokenError, IndentationError, SyntaxError) as exc:
        raise ContractError("reader {} could not be tokenized: {}".format(relative, exc))


def reader_names() -> dict[str, set[str]]:
    """Every FM_AZURE_* name each reader takes, keyed by name."""
    by_name: dict[str, set[str]] = {}
    for relative in READERS:
        found = set(NAME.findall(code_text(relative, read(relative))))
        if not found:
            # A reader that suddenly matches nothing means the derivation broke,
            # not that the lane stopped needing an environment. Fail loudly: a
            # silently empty contract would make the guarding test vacuous.
            raise ContractError(
                "reader {} yielded no FM_AZURE_ names; the derivation is broken".format(relative)
            )
        for name in found:
            by_name.setdefault(name, set()).add(relative)
    return by_name


def run_pilot_create_body(source: str) -> str:
    """Exactly run_pilot_create's own body, sliced by the PARSER.

    The slice matters more than it looks. Any text search from the def to the
    first env.update will happily run PAST the end of the function and match an
    env.update in some LATER helper, and then the subtraction is computed from a
    call the pilot never receives. Moving that block into a helper is an
    ordinary refactor, and the failure it would cause is silent and severe:
    run_pilot_create would supply nothing, so a real deployment would run at
    capacityProfile=foundation with all four worker bindings left "unbound",
    while the contract still printed a plausible set and every test stayed
    green.

    Sliced with ast rather than a terminator regex because a regex has to
    enumerate the shapes that end a function, and the two it missed both
    reopened exactly that hole: `async def` was not in the terminator, and a
    run_pilot_create that is the LAST top-level def fell through to end-of-file
    and swallowed any module-level code after it. ast.end_lineno knows where the
    function ends without anyone having to list the ways it can.
    """
    try:
        module = ast.parse(source)
    except SyntaxError as exc:
        raise ContractError("{} could not be parsed: {}".format(SUPPLIER, exc))
    lines = source.splitlines()
    for node in module.body:
        if (
            isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name == "run_pilot_create"
        ):
            return "\n".join(lines[node.lineno - 1:node.end_lineno])
    raise ContractError(
        "run_pilot_create is not defined at module level in {}; the "
        "provider-supplied subtraction cannot be derived".format(SUPPLIER)
    )


def provider_supplied() -> set[str]:
    # RAW source here, not code_text: ast needs real line layout, and tokenizing
    # flattens it away. Comments are stripped from the matched dict below.
    body = run_pilot_create_body(read(SUPPLIER))
    match = re.search(r"env\.update\((\{.*?\})\)", body, re.S)
    if match is None:
        raise ContractError(
            "run_pilot_create's own body no longer contains an env.update; the "
            "provider-supplied subtraction cannot be derived from {}. If that "
            "call moved into a helper, point this function at the helper - do "
            "NOT let the search widen past the function, which is how it would "
            "silently read some other call's names.".format(SUPPLIER)
        )
    supplied = set(NAME.findall("\n".join(
        line for line in match.group(1).splitlines() if not line.lstrip().startswith("#")
    )))
    if not supplied:
        raise ContractError("run_pilot_create supplies no FM_AZURE_ names; the derivation is broken")
    return supplied


def required() -> dict[str, set[str]]:
    by_name = reader_names()
    for name in provider_supplied() | set(SECRET_BEARING_EXCLUSIONS):
        by_name.pop(name, None)
    if not by_name:
        raise ContractError("the derived cloud-env contract is empty; the derivation is broken")
    return by_name


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("", "--allowlist", "--explain"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        contract = required()
    except ContractError as exc:
        print("fm-cloud-env-contract: {}".format(exc), file=sys.stderr)
        return 1
    names = sorted(contract)
    if mode == "--allowlist":
        print(" ".join(names))
    elif mode == "--explain":
        for name in names:
            print("{}\t{}".format(name, ",".join(sorted(contract[name]))))
    else:
        for name in names:
            print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
