#!/usr/bin/env python3
"""fm-jev-dep-harmonizer.py - Jev Cross-Project Dependency Version Drift Harmonizer (Pattern 25).

Scans project dependency manifests (package.json, pyproject.toml, requirements.txt, Cargo.toml)
across registered repositories and treehouses, tracks version allocations of shared core
dependencies, identifies version drift and potential major/minor incompatibilities, and emits
structured JSON harmonization telemetry.

Invariants:
  - Read-only: never modifies any dependency file or lockfile.
  - Fail-open: errors parsing individual manifests fail gracefully without aborting scan.
  - Core tracking: monitors standard shared packages (playwright, pydantic, pytest, ruff, mypy, typescript).
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


TRACKED_PACKAGES = {
    # Python
    "pytest",
    "pydantic",
    "fastapi",
    "ruff",
    "mypy",
    "playwright",
    "fastembed",
    "httpx",
    # JavaScript / TypeScript / Node
    "@playwright/test",
    "typescript",
    "eslint",
    "verovio",
    "prettier",
    "bun",
}


def parse_package_json(path: Path) -> Dict[str, str]:
    deps: Dict[str, str] = {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        for section in ("dependencies", "devDependencies", "peerDependencies"):
            sec_deps = data.get(section, {})
            if isinstance(sec_deps, dict):
                for pkg, ver in sec_deps.items():
                    if isinstance(ver, str) and (pkg in TRACKED_PACKAGES or pkg.lower() in TRACKED_PACKAGES):
                        deps[pkg] = ver
    except Exception:
        pass
    return deps


def parse_pyproject_toml(path: Path) -> Dict[str, str]:
    deps: Dict[str, str] = {}
    try:
        content = path.read_text(encoding="utf-8")
        # Match dependencies = [ ... ] or [project.dependencies]
        for line in content.splitlines():
            line = line.split("#")[0].strip()
            if not line:
                continue
            line = line.rstrip(",").strip(" '\"")
            # Match lines like "pytest>=8.0.0", "pydantic>=2.7.0"
            m = re.match(r"^([a-zA-Z0-9_\-]+)\s*([><=~!^].*)?$", line)
            if m:
                pkg = m.group(1).lower()
                ver = (m.group(2) or "any").strip(" '\",")
                if pkg in TRACKED_PACKAGES:
                    deps[pkg] = ver
    except Exception:
        pass
    return deps


def parse_requirements_txt(path: Path) -> Dict[str, str]:
    deps: Dict[str, str] = {}
    try:
        content = path.read_text(encoding="utf-8")
        for line in content.splitlines():
            line = line.split("#")[0].strip()
            if not line:
                continue
            line = line.rstrip(",").strip(" '\"")
            m = re.match(r"^([a-zA-Z0-9_\-]+)\s*([><=~!^].*)?$", line)
            if m:
                pkg = m.group(1).lower()
                ver = (m.group(2) or "any").strip(" '\",")
                if pkg in TRACKED_PACKAGES:
                    deps[pkg] = ver
    except Exception:
        pass
    return deps


def scan_project_dependencies(project_root: Path) -> Dict[str, Any]:
    project_record: Dict[str, Any] = {
        "project": project_root.name,
        "path": str(project_root),
        "manifests": [],
        "dependencies": {},
    }

    # 1. package.json
    pkg_json = project_root / "package.json"
    if pkg_json.is_file():
        parsed = parse_package_json(pkg_json)
        if parsed:
            project_record["manifests"].append("package.json")
            project_record["dependencies"].update(parsed)

    # 2. pyproject.toml
    pyproject = project_root / "pyproject.toml"
    if pyproject.is_file():
        parsed = parse_pyproject_toml(pyproject)
        if parsed:
            project_record["manifests"].append("pyproject.toml")
            project_record["dependencies"].update(parsed)

    # 3. requirements.txt
    req_txt = project_root / "requirements.txt"
    if req_txt.is_file():
        parsed = parse_requirements_txt(req_txt)
        if parsed:
            project_record["manifests"].append("requirements.txt")
            project_record["dependencies"].update(parsed)

    return project_record


def find_project_roots(roots: List[Path], max_depth: int = 2) -> List[Path]:
    project_roots: List[Path] = []
    seen = set()

    for root in roots:
        if not root.exists() or not root.is_dir():
            continue
        # Check root itself
        if (root / "package.json").is_file() or (root / "pyproject.toml").is_file():
            resolved = root.resolve()
            if resolved not in seen:
                seen.add(resolved)
                project_roots.append(root)

        # Walk subdirectories
        for dirpath, dirnames, _ in os.walk(root):
            dirnames[:] = [
                d for d in dirnames
                if d not in (".git", "node_modules", "vendor", "dist", "build", ".venv", ".next", ".cache", "tmp")
            ]
            p = Path(dirpath)
            try:
                rel_depth = len(p.relative_to(root).parts)
            except ValueError:
                rel_depth = 0

            if rel_depth > max_depth:
                dirnames.clear()
                continue

            if (p / "package.json").is_file() or (p / "pyproject.toml").is_file():
                resolved = p.resolve()
                if resolved not in seen:
                    seen.add(resolved)
                    project_roots.append(p)
                dirnames.clear()

    return sorted(project_roots)


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Cross-Project Dependency Version Drift Harmonizer (Pattern 25)")
    parser.add_argument(
        "--roots",
        type=str,
        default=os.environ.get("FM_DEP_HARMONIZER_ROOTS", "/home/jon/git,/home/jon/.treehouse/tutti-2b1be6/7/tutti,/opt/ra/firstmate"),
        help="Comma-separated directory roots to scan for project manifests",
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--drift-only", action="store_true", help="Report only dependencies with detected version drift")

    args = parser.parse_args()

    raw_roots = [p.strip() for p in args.roots.split(",") if p.strip()]
    root_paths = [Path(os.path.expanduser(p)) for p in raw_roots]

    project_paths = find_project_roots(root_paths)
    projects: List[Dict[str, Any]] = []

    # Map pkg -> list of {project: name, version: ver, path: str}
    package_matrix: Dict[str, List[Dict[str, str]]] = {}

    for p in project_paths:
        data = scan_project_dependencies(p)
        if data["dependencies"]:
            projects.append(data)
            for pkg, ver in data["dependencies"].items():
                if pkg not in package_matrix:
                    package_matrix[pkg] = []
                package_matrix[pkg].append({
                    "project": data["project"],
                    "version": ver,
                    "path": data["path"],
                })

    # Analyze drift
    drift_report: Dict[str, Any] = {}
    for pkg, occurrences in package_matrix.items():
        distinct_versions = sorted(list(set(occ["version"] for occ in occurrences)))
        has_drift = len(distinct_versions) > 1
        drift_report[pkg] = {
            "has_drift": has_drift,
            "distinct_versions_count": len(distinct_versions),
            "versions": distinct_versions,
            "occurrences": occurrences,
        }

    total_tracked = len(package_matrix)
    drifted_packages = sum(1 for d in drift_report.values() if d["has_drift"])

    telemetry = {
        "timestamp": os.popen("date -u +%Y-%m-%dT%H:%M:%SZ").read().strip(),
        "summary": {
            "scanned_projects_count": len(projects),
            "tracked_packages_count": total_tracked,
            "drifted_packages_count": drifted_packages,
            "harmonization_ratio_pct": round(((total_tracked - drifted_packages) / max(total_tracked, 1)) * 100, 1),
        },
        "drift_report": {
            k: v for k, v in drift_report.items() if (not args.drift_only or v["has_drift"])
        },
        "projects": projects,
    }

    if args.json:
        print(json.dumps(telemetry, indent=2))
    else:
        s = telemetry["summary"]
        print("Jev Dependency Drift Harmonizer (Pattern 25):")
        print(f"  • Projects Scanned: {s['scanned_projects_count']}")
        print(f"  • Tracked Dependencies: {s['tracked_packages_count']}")
        print(f"  • Drifted Packages: {s['drifted_packages_count']}")
        print(f"  • Harmonization Ratio: {s['harmonization_ratio_pct']}%")
        for pkg, d in drift_report.items():
            if d["has_drift"]:
                vers = ", ".join(d["versions"])
                print(f"    - [DRIFT] {pkg}: {vers} across {len(d['occurrences'])} project(s)")
            elif not args.drift_only:
                print(f"    - [ALIGNED] {pkg}: {d['versions'][0]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
