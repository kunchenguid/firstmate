#!/usr/bin/env bash
# fm-diagnostic-report.sh - mechanical checks for diagnostic investigation reports.
#
# Semantic policy is owned by .agents/skills/diagnostic-reasoning/SKILL.md.
# This script evaluates report structure only; it never infers causes from prose.
#
# Usage:
#   fm-diagnostic-report.sh evaluate <report.md>
#   fm-diagnostic-report.sh policy-scan [<repo-root>]
#   fm-diagnostic-report.sh -h | --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-diagnostic-report-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-diagnostic-report-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help|'')
    usage
    exit 0
    ;;
  evaluate)
    ;;
  policy-scan)
    SCAN_ROOT=${2:-$SCRIPT_DIR/..}
    if [ ! -d "$SCAN_ROOT" ]; then
      printf 'fm-diagnostic-report: policy-scan root is missing: %s\n' "$SCAN_ROOT" >&2
      exit 1
    fi
    if hits=$(fm_diagnostic_hypothesis_policy_scan "$SCAN_ROOT"); then
      printf 'fm-diagnostic-report: ok policy=single-declared-owner\n'
      exit 0
    fi
    rc=$?
    if [ "$rc" -eq 2 ]; then
      exit 2
    fi
    printf 'fm-diagnostic-report: hypothesis-table policy declaration is invalid:\n%s\n' "$hits" >&2
    exit 1
    ;;
  *)
    printf 'fm-diagnostic-report: unknown command: %s\n' "${1:-}" >&2
    usage >&2
    exit 2
    ;;
esac

REPORT=${2:-}
if [ -z "$REPORT" ]; then
  printf 'fm-diagnostic-report: evaluate requires a report path\n' >&2
  exit 2
fi
if [ ! -f "$REPORT" ]; then
  printf 'fm-diagnostic-report: report is missing: %s\n' "$REPORT" >&2
  exit 1
fi

export FM_DIAGNOSTIC_HYPOTHESIS_COLUMNS FM_DIAGNOSTIC_HYPOTHESIS_VERDICTS
exec python3 - "$REPORT" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPORT = Path(sys.argv[1])
COLUMNS = os.environ["FM_DIAGNOSTIC_HYPOTHESIS_COLUMNS"].split()
VERDICTS = set(os.environ["FM_DIAGNOSTIC_HYPOTHESIS_VERDICTS"].split())
TABLE_HEADER_RE = re.compile(r"^\|\s*hypothesis\s*\|", re.IGNORECASE)
ROW_RE = re.compile(r"^\|(.+)\|$")
FENCE_RE = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})(.*)$")
SEPARATOR_CELL_RE = re.compile(r"^:?-{3,}:?$")


class EvalError(Exception):
    pass


def fail(message: str) -> None:
    raise EvalError(message)


def split_cells(line: str) -> list[str]:
    body = line.strip()
    if not body.startswith("|") or not body.endswith("|"):
        fail("hypothesis table row is not pipe-delimited markdown")
    return [cell.strip() for cell in body.strip("|").split("|")]


def is_separator_row(line: str) -> bool:
    stripped = line.strip()
    if not ROW_RE.match(stripped):
        return False
    cells = split_cells(stripped)
    return bool(cells) and all(SEPARATOR_CELL_RE.match(cell) for cell in cells)


def markdown_context_flags(lines: list[str]) -> list[tuple[bool, bool]]:
    """Return blocked (fence/comment/indented-code) flags for each line."""
    flags: list[tuple[bool, bool]] = []
    in_fence = False
    fence_char = ""
    fence_length = 0
    in_html_comment = False
    for line in lines:
        fence = FENCE_RE.match(line)
        indented_code = line.startswith("    ") or line.startswith("\t")
        if in_fence:
            flags.append((True, False))
            if (fence and not fence.group(2).strip() and fence.group(1)[0] == fence_char
                    and len(fence.group(1)) >= fence_length):
                in_fence = False
                fence_char = ""
                fence_length = 0
            continue
        if in_html_comment:
            flags.append((False, True))
            if "-->" in line:
                in_html_comment = False
            continue
        if fence and not indented_code:
            in_fence = True
            fence_char = fence.group(1)[0]
            fence_length = len(fence.group(1))
            flags.append((True, False))
            continue
        if "<!--" in line:
            in_html_comment = "-->" not in line[line.index("<!--") + 4 :]
            flags.append((False, True))
            continue
        flags.append((False, indented_code))
    return flags


def find_table_header(lines: list[str], flags: list[tuple[bool, bool]]) -> int:
    for index, line in enumerate(lines):
        if not any(flags[index]) and TABLE_HEADER_RE.match(line):
            return index
    fail("report is missing a Hypothesis table header row")


def parse_table(lines: list[str]) -> tuple[list[str], list[list[str]]]:
    flags = markdown_context_flags(lines)
    header_idx = find_table_header(lines, flags)
    end = header_idx + 4
    if end > len(lines):
        fail("hypothesis table must contain exactly two hypothesis rows")
    if any(any(flags[index]) for index in range(header_idx, end)):
        fail("hypothesis table must be outside fenced code, comments, and indented code")
    header = [cell.lower() for cell in split_cells(lines[header_idx])]
    if len(header) != len(COLUMNS):
        fail("hypothesis table header has the wrong column width")
    for column in COLUMNS:
        if column not in header:
            fail(f"hypothesis table is missing the {column} column")
    separator = split_cells(lines[header_idx + 1]) if ROW_RE.match(lines[header_idx + 1]) else []
    if len(separator) != len(header) or not all(SEPARATOR_CELL_RE.match(cell) for cell in separator):
        fail("hypothesis table header is not followed by a valid markdown separator row")
    rows: list[list[str]] = []
    for line in lines[header_idx + 2 : end]:
        cells = split_cells(line)
        if len(cells) != len(header):
            fail("hypothesis table row width does not match the header")
        row = {header[i]: cells[i] for i in range(len(header))}
        for column in COLUMNS:
            if not row[column].strip():
                fail(f"hypothesis table row has empty {column} cell")
        rows.append([row[column] for column in COLUMNS])
    if len(rows) != 2:
        fail("hypothesis table must contain exactly two hypothesis rows")
    if end < len(lines) and not any(flags[end]) and ROW_RE.match(lines[end]):
        fail("hypothesis table must contain exactly two hypothesis rows")
    return header, rows


def main() -> int:
    try:
        text = REPORT.read_text(encoding="utf-8")
        _, rows = parse_table(text.splitlines())
        for index, row in enumerate(rows, start=1):
            verdict = row[-1].strip().lower()
            if verdict not in VERDICTS:
                fail(
                    "hypothesis row "
                    f"{index} verdict must be one of {', '.join(sorted(VERDICTS))}, got {row[-1]!r}"
                )
    except EvalError as exc:
        print(f"fm-diagnostic-report: {exc}", file=sys.stderr)
        return 1
    print("fm-diagnostic-report: ok rows=2 verdicts=closed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
