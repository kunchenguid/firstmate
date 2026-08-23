#!/usr/bin/env bash
# fm-delivery-mode-check.sh - bidirectional drift guard for the ship delivery-mode
# closed set (AGENTS.md section 7: no-mistakes, direct-PR, local-only, plus the
# registry-only policy no-mistakes-prod-only).
#
# Usage:
#   bin/fm-delivery-mode-check.sh
#   bin/fm-delivery-mode-check.sh --root <repo> [--registry <path>]
#
# Six scripts independently validate this closed set with their own `case`
# statement (fm-brief.sh, fm-spawn.sh, fm-promote.sh, fm-project-mode.sh,
# fm-remote-home-provision.sh, fm-remote-home-seed.sh) because each must refuse
# an invalid mode on its own, without depending on another script having run
# first. bin/fm-delivery-mode-sites.json is the single declared inventory of
# which sites exist and which subset of the closed set each one accepts; this
# script is what keeps that declaration honest against the actual code instead
# of letting it rot into unverified prose.
#
# It greps every tracked bin/*.sh for a `case`-arm-shaped closed-set alternation
# built only from the registry's own "modes" vocabulary (two or more
# pipe-joined literals immediately before a `)`), then fails on either
# direction of drift: a site the registry declares whose file no longer has a
# matching arm (or whose arm now accepts something else), or a matching arm in
# a file the registry never mentions. This is the same registry-vs-reality
# pattern documented in data/learnings.md ("closed-set guard enforcing 9 of its
# 11 declared sites") applied to firstmate's own delivery-mode contract.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


class CheckError(Exception):
    """One deterministic delivery-mode drift failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git_tracked(root: Path, patterns: list[str]) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *patterns],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def load_registry(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"registry is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"registry is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("registry root must be an object")
    if data.get("version") != 1:
        fail("registry version must be 1")
    return data


def list_of_strings(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        fail(f"{label} must be a non-empty string array")
    return value


def build_arm_pattern(modes: list[str]) -> re.Pattern:
    # Longest-first so an alternation attempt can't stop early on a shorter
    # token that is itself a prefix of a longer one (no-mistakes is a prefix
    # of no-mistakes-prod-only).
    tokens = sorted(modes, key=len, reverse=True)
    alt = "|".join(re.escape(t) for t in tokens)
    # At least two alternatives: a single bare mode in a case arm (e.g. the
    # no-mistakes-prod-only rejection arm) is not a closed-set check.
    return re.compile(rf"(?<![A-Za-z0-9_-])((?:{alt})(?:\|(?:{alt}))+)\)")


def sites_declaring(root: Path, path: str, pattern: re.Pattern) -> set[frozenset[str]]:
    full = root / path
    try:
        text = full.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read delivery-mode site {path}: {exc}")
    found: set[frozenset[str]] = set()
    for match in pattern.finditer(text):
        found.add(frozenset(match.group(1).split("|")))
    return found


def validate(root: Path, registry_path: Path) -> tuple[int, int]:
    data = load_registry(registry_path)
    modes = list_of_strings(data.get("modes"), "modes")
    if len(set(modes)) != len(modes):
        fail("modes must not contain duplicates")

    sites = data.get("sites")
    if not isinstance(sites, list) or not sites:
        fail("sites must be a non-empty array")

    registered: dict[str, frozenset[str]] = {}
    for index, entry in enumerate(sites):
        if not isinstance(entry, dict):
            fail(f"sites[{index}] must be an object")
        path = entry.get("path")
        accepts = entry.get("accepts")
        if not isinstance(path, str) or not path:
            fail(f"sites[{index}].path must be a non-empty string")
        accepts = list_of_strings(accepts, f"sites[{index}].accepts")
        unknown = [m for m in accepts if m not in modes]
        if unknown:
            fail(f"{path}: accepts an unregistered mode {unknown!r}; add it to \"modes\" first")
        if len(set(accepts)) != len(accepts):
            fail(f"{path}: accepts lists a mode more than once")
        if path in registered:
            fail(f"{path}: declared as a site more than once")
        registered[path] = frozenset(accepts)

    pattern = build_arm_pattern(modes)
    tracked = set(git_tracked(root, ["bin/*.sh"]))

    missing_files = sorted(p for p in registered if p not in tracked)
    if missing_files:
        fail("registered site is not a tracked bin/*.sh file: " + ", ".join(missing_files))

    discovered: dict[str, set[frozenset[str]]] = {}
    for path in sorted(tracked):
        found = sites_declaring(root, path, pattern)
        if found:
            discovered[path] = found

    unregistered = sorted(set(discovered) - set(registered))
    if unregistered:
        details = ", ".join(
            f"{path} declares {{{'|'.join(sorted(next(iter(discovered[path])))) }}}"
            for path in unregistered
        )
        fail("closed-set case arm found in a file the registry does not mention: " + details)

    drifted = []
    for path, accepts in registered.items():
        found = discovered.get(path)
        if not found:
            drifted.append(f"{path}: registry declares {{{'|'.join(sorted(accepts))}}} but no matching case arm exists in the file")
            continue
        if len(found) > 1:
            rendered = "; ".join("{" + "|".join(sorted(s)) + "}" for s in sorted(found, key=sorted))
            drifted.append(f"{path}: more than one distinct closed-set case arm found ({rendered}); registry cannot cross-check it unambiguously")
            continue
        actual = next(iter(found))
        if actual != accepts:
            drifted.append(
                f"{path}: registry declares {{{'|'.join(sorted(accepts))}}} "
                f"but the file's case arm actually accepts {{{'|'.join(sorted(actual))}}}"
            )
    if drifted:
        fail("; ".join(drifted))

    return len(registered), len(modes)


def main() -> int:
    parser = argparse.ArgumentParser(description="Cross-check the delivery-mode site registry against the real bin/ scripts.")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--registry", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    registry_path = args.registry or (root / "bin/fm-delivery-mode-sites.json")
    if not registry_path.is_absolute():
        registry_path = root / registry_path
    try:
        sites, modes = validate(root, registry_path)
    except CheckError as exc:
        print(f"fm-delivery-mode-check: {exc}", file=sys.stderr)
        return 1
    print(f"fm-delivery-mode-check: ok sites={sites} modes={modes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
