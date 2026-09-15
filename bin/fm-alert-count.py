#!/usr/bin/env python3
"""Count live Dependabot alerts that an npm package-lock branch proves it remediates.

Usage:
  fm-alert-count.py <base-ref> <head-ref>

The command reads the live open Dependabot alert list for origin's GitHub
repository through gh-axi, then evaluates each alert's package-lock manifest at
the supplied base and head refs against every npm vulnerable range the advisory
publishes for that package.
An alert counts as remediated only when base holds a copy inside a vulnerable
range and head holds none. It is deliberately fail-closed: an unsupported
manifest, a lockfile without a packages object, a non-semver or prerelease
installed version, or an unparseable vulnerable range is reported as not
checked, never counted as remediated.
Output is silent only when the live default-branch alert list is empty.
"""

from __future__ import annotations

import base64
import json
import operator
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import PurePosixPath


REPO_RE = re.compile(r"(?:git@github\.com:|https://github\.com/)([^/\s]+)/([^/\s]+?)(?:\.git)?$")
SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$")
RANGE_RE = re.compile(r"(<=|>=|<|>|=)\s*(\S+)")
BASE64_PAGE = r"[A-Za-z0-9+/=]+"
BODY_RE = re.compile(rf'^\s*body: (?:"({BASE64_PAGE}(?:\\n{BASE64_PAGE})*)"|({BASE64_PAGE}))\s*$', re.MULTILINE)
OPERATORS = {"<": operator.lt, "<=": operator.le, ">": operator.gt, ">=": operator.ge, "=": operator.eq}
RELEASE = ((2,),)


class CheckError(Exception):
    pass


def run(*args: str) -> str:
    completed = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip() or "command failed"
        raise CheckError(f"{' '.join(args[:2])}: {detail}")
    return completed.stdout


def repository() -> str:
    remote = run("git", "remote", "get-url", "origin").strip()
    match = REPO_RE.fullmatch(remote)
    if not match:
        raise CheckError("origin is not a GitHub repository, so the live alert list was not checked")
    return f"{match.group(1)}/{match.group(2)}"


def gh_axi_pages(output: str) -> list[str]:
    """Extract the per-page base64 lines from gh-axi's TOON body scalar without parsing presentation YAML."""
    match = BODY_RE.search(output)
    if not match:
        raise CheckError("gh-axi returned no readable alert data")
    return (match.group(1) or match.group(2)).split("\\n")


def live_alerts(repo: str) -> list[dict[str, object]]:
    query = (
        "[.[] | {number, dependency, security_advisory: {vulnerabilities: .security_advisory.vulnerabilities}}] | @base64"
    )
    output = run(
        "gh-axi",
        "api",
        f"/repos/{repo}/dependabot/alerts?state=open&per_page=100",
        "--paginate",
        "--jq",
        query,
        "--full",
    )
    alerts: list[dict[str, object]] = []
    for body in gh_axi_pages(output):
        try:
            page = json.loads(base64.b64decode(body, validate=True))
        except (ValueError, json.JSONDecodeError) as exc:
            raise CheckError(f"gh-axi returned malformed alert data: {exc}") from exc
        if not isinstance(page, list) or not all(isinstance(alert, dict) for alert in page):
            raise CheckError("gh-axi returned an unexpected alert list")
        alerts.extend(page)
    return alerts


def git_file(ref: str, path: str) -> bytes:
    completed = subprocess.run(("git", "show", f"{ref}:{path}"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        raise CheckError(f"{path} is unavailable at {ref}")
    return completed.stdout


def package_name_from_path(path: str) -> str | None:
    parts = PurePosixPath(path).parts
    indexes = [index for index, part in enumerate(parts) if part == "node_modules"]
    if not indexes:
        return None
    start = indexes[-1] + 1
    if start >= len(parts):
        return None
    if parts[start].startswith("@") and start + 1 < len(parts):
        return f"{parts[start]}/{parts[start + 1]}"
    return parts[start]


def lock_versions(raw: bytes) -> dict[str, list[str]]:
    try:
        lock = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CheckError(f"package-lock.json is not valid JSON: {exc}") from exc
    packages = lock.get("packages") if isinstance(lock, dict) else None
    if not isinstance(packages, dict):
        raise CheckError("package-lock.json has no packages object")
    versions: dict[str, list[str]] = defaultdict(list)
    for path, item in packages.items():
        if not isinstance(path, str) or not isinstance(item, dict):
            continue
        package = package_name_from_path(path)
        name = item.get("name")
        version = item.get("version")
        if package and isinstance(version, str):
            versions[name if isinstance(name, str) else package].append(version)
    return versions


def semver(version: str) -> tuple[int, int, int, tuple] | None:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        return None
    major, minor, patch, prerelease = match.groups()
    tag = tuple((0, int(part)) if part.isdigit() else (1, part) for part in prerelease.split(".")) if prerelease else RELEASE
    return int(major), int(minor), int(patch), tag


def parse_range(text: object) -> list[tuple[str, tuple]] | None:
    if not isinstance(text, str):
        return None
    bounds = []
    for part in text.split(","):
        match = RANGE_RE.fullmatch(part.strip())
        if not match:
            return None
        op, version = match.groups()
        if version.count(".") < 2:
            if op not in {">", ">="} or any(component != "0" for component in version.split(".")):
                return None
            version = "0.0.0"
        bound = semver(version)
        if bound is None:
            return None
        bounds.append((op, bound))
    return bounds


def vulnerable_ranges(package: str, vulnerabilities: list[object]) -> list[tuple[list[tuple[str, tuple]], str | None]]:
    ranges = []
    for vulnerability in vulnerabilities:
        if not isinstance(vulnerability, dict) or not isinstance(vulnerability.get("package"), dict):
            raise CheckError("malformed advisory vulnerability")
        affected = vulnerability["package"]
        if str(affected.get("ecosystem")).lower() != "npm" or affected.get("name") != package:
            continue
        text = vulnerability.get("vulnerable_version_range")
        bounds = parse_range(text)
        if bounds is None:
            raise CheckError(f"unparseable advisory range {text!r}")
        first_patched = vulnerability.get("first_patched_version")
        patched = first_patched.get("identifier") if isinstance(first_patched, dict) else None
        if first_patched is not None and not (isinstance(patched, str) and semver(patched)):
            raise CheckError(f"unparseable first patched version {patched!r}")
        ranges.append((bounds, patched))
    if not ranges:
        raise CheckError("advisory publishes no npm vulnerable range")
    return ranges


def vulnerable_copies(versions: list[str], ranges: list[tuple[list[tuple[str, tuple]], str | None]]) -> list[tuple[tuple, str | None]]:
    copies = []
    for version in versions:
        parsed = semver(version)
        if parsed is None or parsed[3] != RELEASE:
            raise CheckError(f"non-semver or prerelease package-lock version {version}")
        copies.extend(
            (parsed, patched) for bounds, patched in ranges if all(OPERATORS[op](parsed, bound) for op, bound in bounds)
        )
    return copies


def alert_fields(alert: dict[str, object]) -> tuple[int, str, str, list[object]] | None:
    number = alert.get("number")
    dependency = alert.get("dependency")
    advisory = alert.get("security_advisory")
    if not isinstance(number, int) or not isinstance(dependency, dict) or not isinstance(advisory, dict):
        return None
    package = dependency.get("package")
    manifest = dependency.get("manifest_path")
    vulnerabilities = advisory.get("vulnerabilities")
    if (
        not isinstance(package, dict)
        or not isinstance(package.get("name"), str)
        or not isinstance(manifest, str)
        or not isinstance(vulnerabilities, list)
    ):
        return None
    return number, package["name"], manifest.lstrip("/"), vulnerabilities


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] in {"-h", "--help"}:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    base, head = argv[1:]
    try:
        repo = repository()
        alerts = live_alerts(repo)
    except CheckError as exc:
        print(f"NOT CHECKED: {exc}")
        return 1
    if not alerts:
        return 0

    remediated: list[str] = []
    excluded: list[str] = []
    unchecked: list[str] = []
    caches: dict[tuple[str, str], dict[str, list[str]]] = {}

    for raw_alert in alerts:
        fields = alert_fields(raw_alert)
        if fields is None:
            number = raw_alert.get("number")
            unchecked.append(f"#{number} malformed live alert record" if isinstance(number, int) else "malformed live alert record")
            continue
        number, package, manifest, vulnerabilities = fields
        label = f"#{number} {package} ({manifest})"
        if PurePosixPath(manifest).name != "package-lock.json":
            unchecked.append(f"{label}: unsupported manifest")
            continue
        try:
            ranges = vulnerable_ranges(package, vulnerabilities)
            for ref in (base, head):
                key = (ref, manifest)
                if key not in caches:
                    caches[key] = lock_versions(git_file(ref, manifest))
            base_copies = vulnerable_copies(caches[(base, manifest)].get(package, []), ranges)
            head_copies = vulnerable_copies(caches[(head, manifest)].get(package, []), ranges)
        except CheckError as exc:
            unchecked.append(f"{label}: {exc}")
            continue
        patches = {patched for _, patched in head_copies}
        if not base_copies and not head_copies:
            excluded.append(f"{label}: already resolved on {base}")
        elif not base_copies:
            excluded.append(f"{label}: {head} reintroduces a vulnerable copy")
        elif not head_copies:
            remediated.append(label)
        elif None in patches:
            excluded.append(f"{label}: no patched version published")
        elif all(semver(patched)[0] > version[0] for version, patched in head_copies):
            excluded.append(f"{label}: rejected major, patch requires {', '.join(sorted(patches))}")
        else:
            excluded.append(f"{label}: {head} does not reach a patched version")

    print(f"VERIFIED BRANCH REMEDIATION COUNT: {len(remediated)} ({', '.join(remediated) or 'none'})")
    print(
        f"DEFAULT-BRANCH CAVEAT: {len(remediated)} verified branch remediation(s) close none now. "
        "Dependabot advisories attach to the default branch and close only after release to it."
    )
    print("EXCLUDED FROM THE VERIFIED COUNT:")
    for item in excluded:
        print(f"- {item}")
    if unchecked:
        print("NOT CHECKED:")
        for item in unchecked:
            print(f"- {item}")
        return 1
    print("NOT CHECKED: none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
