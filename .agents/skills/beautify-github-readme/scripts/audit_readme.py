#!/usr/bin/env python3
"""Audit local README image references and basic SVG compatibility."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)")
HTML_IMAGE = re.compile(r"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"'][^>]*>", re.I)
HTML_ALT = re.compile(r"\balt=[\"']([^\"']*)[\"']", re.I)
UNSAFE_SVG_TAGS = {"script", "foreignObject"}


def local_target(src: str, base: Path) -> Path | None:
    if src.startswith(("http://", "https://", "data:", "#")):
        return None
    clean = src.split("#", 1)[0].split("?", 1)[0]
    return (base / clean).resolve()


def audit_svg(path: Path) -> list[str]:
    issues: list[str] = []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        return [f"invalid SVG XML: {exc}"]

    if "viewBox" not in root.attrib:
        issues.append("missing viewBox")

    title_found = False
    for node in root.iter():
        tag = node.tag.rsplit("}", 1)[-1]
        if tag == "title":
            title_found = True
        if tag in UNSAFE_SVG_TAGS:
            issues.append(f"contains unsupported <{tag}>")
    if not title_found:
        issues.append("missing <title>")
    return issues


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: audit_readme.py /path/to/README.md", file=sys.stderr)
        return 2

    readme = Path(sys.argv[1]).expanduser().resolve()
    if not readme.is_file():
        print(f"ERROR: README not found: {readme}")
        return 2

    text = readme.read_text(encoding="utf-8")
    sources = MARKDOWN_IMAGE.findall(text)
    html_tags = re.findall(r"<img\b[^>]*>", text, flags=re.I)
    sources.extend(HTML_IMAGE.findall(text))

    warnings: list[str] = []
    for tag in html_tags:
        match = HTML_ALT.search(tag)
        if not match or not match.group(1).strip():
            warnings.append(f"HTML image missing useful alt text: {tag[:100]}")

    checked = 0
    for src in dict.fromkeys(sources):
        target = local_target(src, readme.parent)
        if target is None:
            continue
        checked += 1
        if not target.is_file():
            warnings.append(f"missing image: {src}")
            continue
        if target.suffix.lower() == ".svg":
            for issue in audit_svg(target):
                warnings.append(f"{src}: {issue}")

    print(f"README: {readme}")
    print(f"Local images checked: {checked}")
    if warnings:
        print("Issues:")
        for warning in warnings:
            print(f"- {warning}")
        return 1
    print("OK: image references and SVG basics passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
