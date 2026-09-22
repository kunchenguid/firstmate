#!/usr/bin/env bash
# Validate code-marked owner paths in nested harness-adapter references.
# Usage: fm-harness-adapter-path-check.sh [--skill-dir <directory>]
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$SELF_DIR/../.agents/skills/harness-adapters"

case "${1:-}" in
  "") ;;
  --skill-dir)
    [ "$#" -eq 2 ] || {
      echo "usage: fm-harness-adapter-path-check.sh [--skill-dir <directory>]" >&2
      exit 2
    }
    SKILL_DIR=$2
    ;;
  -h|--help)
    echo "usage: fm-harness-adapter-path-check.sh [--skill-dir <directory>]"
    exit 0
    ;;
  *)
    echo "usage: fm-harness-adapter-path-check.sh [--skill-dir <directory>]" >&2
    exit 2
    ;;
esac

exec python3 - "$SKILL_DIR" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

CODE_SPAN = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")


def main() -> int:
    skill = Path(sys.argv[1]).resolve()
    references = skill / "references"
    if not references.is_dir():
        print(f"fm-harness-adapter-path-check: references directory is missing: {references}", file=sys.stderr)
        return 1

    files = sorted(references.rglob("*.md"))
    failures: list[str] = []
    checked = 0
    for source in files:
        try:
            lines = source.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            failures.append(f"cannot read {source.relative_to(skill)}: {exc}")
            continue
        for line_number, line in enumerate(lines, 1):
            for span in CODE_SPAN.findall(line):
                for token in span.split():
                    path = token.split("#", 1)[0].rstrip(".,:;")
                    if not (path.startswith("../") or path.startswith("references/")):
                        continue
                    checked += 1
                    if not (skill / path).exists():
                        failures.append(f"{source.relative_to(skill)}:{line_number}: unresolved owner path: {path}")

    if failures:
        for failure in failures:
            print(f"fm-harness-adapter-path-check: {failure}", file=sys.stderr)
        return 1
    print(f"fm-harness-adapter-path-check: ok references={len(files)} owner_paths={checked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
