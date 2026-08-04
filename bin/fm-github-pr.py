#!/usr/bin/env python3
"""Strict adapter for the installed gh-axi pull-request surface.

Observed against gh-axi 0.1.25 on 2026-08-02:

* ``gh-axi api /repos/<owner>/<repo>/pulls/<number>`` emits a nested TOON
  document whose ``head.sha`` and ``base.sha`` values are exact Git SHAs.
* ``gh-axi pr view <number> --repo <owner>/<repo> --full`` emits the complete
  pull-request claims as a ``pull_request:`` TOON document.
* ``gh-axi api PUT .../merge --field sha=<sha> --field merge_method=<method>``
  emits root ``sha``, ``merged``, and ``message`` fields on success.

A successful merge request can enqueue a pull request instead of merging it.
That outcome is reported as ``enqueued/unconfirmed`` only after a fresh API
read confirms that the same reviewed head remains open and unmerged.

The adapter deliberately does not pass raw-gh ``--json`` or ``-q`` flags.
It fails closed when gh-axi exits nonzero or its observed document shape is
missing, duplicated, malformed, or inconsistent with the requested PR.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any


BIN_DIR = Path(__file__).resolve().parent
if str(BIN_DIR) not in sys.path:
    sys.path.insert(0, str(BIN_DIR))

from fm_bounded_io import BoundedIOError, run_bounded


PR_URL_RE = re.compile(
    r"^https://github\.com/"
    r"(?P<owner>[A-Za-z0-9][A-Za-z0-9-]{0,38})/"
    r"(?P<repo>[A-Za-z0-9._-]+)/pull/(?P<number>[0-9]+)/?$"
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ARRAY_HEADER_RE = re.compile(
    r"^(?P<key>[A-Za-z_][A-Za-z0-9_]*)"
    r"\[(?P<count>0|[1-9][0-9]*)\]"
    r"(?:\{(?P<fields>[A-Za-z_][A-Za-z0-9_]*"
    r"(?:,[A-Za-z_][A-Za-z0-9_]*)*)\})?:$"
)
MAX_GH_AXI_OUTPUT_BYTES = 1_000_000


class GitHubContractError(RuntimeError):
    """Raised when the external GitHub contract cannot be established."""


def parse_pr_url(url: str) -> tuple[str, str, int]:
    match = PR_URL_RE.fullmatch(url)
    if match is None or match.group("owner").endswith("-"):
        raise GitHubContractError(
            "PR URL must match https://github.com/<owner>/<repo>/pull/<number>"
        )
    return match.group("owner"), match.group("repo"), int(match.group("number"))


def _parse_scalar(raw: str, line_number: int) -> Any:
    if raw.startswith(('"', "[", "{")):
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise GitHubContractError(
                f"malformed gh-axi TOON scalar at line {line_number}: {exc.msg}"
            ) from exc
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw == "null":
        return None
    if re.fullmatch(r"-?[0-9]+", raw):
        return int(raw)
    if not raw or any(char in raw for char in "\r\n"):
        raise GitHubContractError(
            f"malformed gh-axi TOON scalar at line {line_number}"
        )
    return raw


def _split_table_row(raw: str, line_number: int) -> list[str]:
    cells: list[str] = []
    start = 0
    quoted = False
    escaped = False
    nesting = 0
    for index, character in enumerate(raw):
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
            continue
        if character == '"':
            quoted = True
        elif character in "[{":
            nesting += 1
        elif character in "]}":
            nesting -= 1
            if nesting < 0:
                raise GitHubContractError(
                    f"malformed gh-axi TOON table row at line {line_number}"
                )
        elif character == "," and nesting == 0:
            cells.append(raw[start:index].strip())
            start = index + 1
    if quoted or escaped or nesting != 0:
        raise GitHubContractError(
            f"malformed gh-axi TOON table row at line {line_number}"
        )
    cells.append(raw[start:].strip())
    return cells


def _mapping_entry(content: str, line_number: int) -> tuple[str, str]:
    if ":" not in content:
        raise GitHubContractError(
            f"malformed gh-axi TOON mapping at line {line_number}"
        )
    key, raw_value = content.split(":", 1)
    if KEY_RE.fullmatch(key) is None:
        raise GitHubContractError(
            f"malformed gh-axi TOON key at line {line_number}"
        )
    return key, raw_value.lstrip(" ")


def _validate_mapping_block(
    lines: list[tuple[int, int, str]],
    index: int,
    parent_depth: int,
    initial_keys: set[str] | None = None,
) -> int:
    keys = set(initial_keys or ())
    while index < len(lines) and lines[index][1] > parent_depth:
        line_number, depth, content = lines[index]
        if depth != parent_depth + 1:
            raise GitHubContractError(
                f"malformed gh-axi TOON nesting at line {line_number}"
            )
        array_header = ARRAY_HEADER_RE.fullmatch(content)
        if array_header is not None:
            key = array_header.group("key")
            if key in keys:
                raise GitHubContractError(f"duplicate gh-axi TOON field {key}")
            keys.add(key)
            index = _validate_array_subtree(lines, index, array_header)
            continue
        key, raw_value = _mapping_entry(content, line_number)
        if key in keys:
            raise GitHubContractError(f"duplicate gh-axi TOON field {key}")
        keys.add(key)
        index += 1
        if raw_value == "":
            if index >= len(lines) or lines[index][1] <= depth:
                raise GitHubContractError(
                    f"malformed empty gh-axi TOON section at line {line_number}"
                )
            index = _validate_mapping_block(lines, index, depth)
        else:
            _parse_scalar(raw_value, line_number)
    return index


def _validate_array_subtree(
    lines: list[tuple[int, int, str]],
    index: int,
    header: re.Match[str],
) -> int:
    line_number, depth, _ = lines[index]
    count = int(header.group("count"))
    fields_text = header.group("fields")
    fields = fields_text.split(",") if fields_text is not None else None
    if fields is not None and len(set(fields)) != len(fields):
        raise GitHubContractError(
            f"duplicate gh-axi TOON table field at line {line_number}"
        )
    index += 1
    child_start = index

    if fields is not None:
        rows = 0
        while index < len(lines) and lines[index][1] > depth:
            row_line, row_depth, content = lines[index]
            if row_depth != depth + 1:
                raise GitHubContractError(
                    f"malformed gh-axi TOON table nesting at line {row_line}"
                )
            cells = _split_table_row(content, row_line)
            if len(cells) != len(fields):
                raise GitHubContractError(
                    f"gh-axi TOON table row at line {row_line} has {len(cells)} "
                    f"cells, expected {len(fields)}"
                )
            for cell in cells:
                _parse_scalar(cell, row_line)
            rows += 1
            index += 1
        if rows != count:
            raise GitHubContractError(
                f"gh-axi TOON array at line {line_number} declares {count} rows, "
                f"found {rows}"
            )
        return index

    if count == 0:
        if index < len(lines) and lines[index][1] > depth:
            raise GitHubContractError(
                f"gh-axi TOON array at line {line_number} declares 0 items but is nonempty"
            )
        return index
    if child_start >= len(lines) or lines[child_start][1] <= depth:
        raise GitHubContractError(
            f"gh-axi TOON array at line {line_number} declares {count} items, found 0"
        )

    first_content = lines[child_start][2]
    object_items = first_content.startswith("- ") and ":" in first_content[2:]
    items = 0
    if object_items:
        while index < len(lines) and lines[index][1] > depth:
            item_line, item_depth, content = lines[index]
            if item_depth != depth + 1 or not content.startswith("- "):
                raise GitHubContractError(
                    f"malformed gh-axi TOON object array at line {item_line}"
                )
            key, raw_value = _mapping_entry(content[2:], item_line)
            items += 1
            index += 1
            if raw_value == "":
                if index >= len(lines) or lines[index][1] <= item_depth:
                    raise GitHubContractError(
                        f"malformed empty gh-axi TOON section at line {item_line}"
                    )
                index = _validate_mapping_block(lines, index, item_depth)
            else:
                _parse_scalar(raw_value, item_line)
                index = _validate_mapping_block(
                    lines, index, item_depth, initial_keys={key}
                )
    else:
        while index < len(lines) and lines[index][1] > depth:
            item_line, item_depth, content = lines[index]
            if item_depth != depth + 1 or not content.startswith("- "):
                raise GitHubContractError(
                    f"malformed gh-axi TOON scalar array item at line {item_line}"
                )
            scalar = content[2:]
            _parse_scalar(scalar, item_line)
            items += 1
            index += 1
    if items != count:
        raise GitHubContractError(
            f"gh-axi TOON array at line {line_number} declares {count} items, "
            f"found {items}"
        )
    return index


def parse_toon_mapping(document: str) -> dict[tuple[str, ...], Any]:
    """Parse required mappings after validating unrelated TOON array subtrees."""

    values: dict[tuple[str, ...], Any] = {}
    sections: set[tuple[str, ...]] = set()
    stack: list[str] = []
    lines: list[tuple[int, int, str]] = []
    for line_number, raw_line in enumerate(document.splitlines(), start=1):
        if not raw_line.strip():
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent % 2:
            raise GitHubContractError(
                f"malformed gh-axi TOON indentation at line {line_number}"
            )
        lines.append((line_number, indent // 2, raw_line[indent:]))

    if not lines:
        raise GitHubContractError("gh-axi returned an empty document")

    index = 0
    while index < len(lines):
        line_number, depth, content = lines[index]
        if depth > len(stack):
            raise GitHubContractError(
                f"malformed gh-axi TOON nesting at line {line_number}"
            )
        stack = stack[:depth]
        array_header = ARRAY_HEADER_RE.fullmatch(content)
        if array_header is not None:
            key = array_header.group("key")
            path = tuple(stack + [key])
            if path in values or path in sections:
                raise GitHubContractError(
                    f"duplicate gh-axi TOON field {'.'.join(path)}"
                )
            sections.add(path)
            index = _validate_array_subtree(lines, index, array_header)
            continue
        key, raw_value = _mapping_entry(content, line_number)
        path = tuple(stack + [key])
        if path in values or path in sections:
            raise GitHubContractError(
                f"duplicate gh-axi TOON field {'.'.join(path)}"
            )
        if raw_value == "":
            sections.add(path)
            stack.append(key)
        else:
            values[path] = _parse_scalar(raw_value, line_number)
        index += 1

    return values


def _required(values: dict[tuple[str, ...], Any], *path: str) -> Any:
    key = tuple(path)
    if key not in values:
        raise GitHubContractError(f"gh-axi document is missing {'.'.join(path)}")
    return values[key]


def _command_timeout() -> int:
    raw = os.environ.get("FM_GH_AXI_TIMEOUT_SECONDS", "60")
    try:
        timeout = int(raw)
    except ValueError as exc:
        raise GitHubContractError("FM_GH_AXI_TIMEOUT_SECONDS must be an integer") from exc
    if timeout < 1 or timeout > 600:
        raise GitHubContractError(
            "FM_GH_AXI_TIMEOUT_SECONDS must be between 1 and 600"
        )
    return timeout


def run_gh_axi(arguments: list[str]) -> str:
    binary = os.environ.get("FM_GH_AXI_BIN", "gh-axi")
    try:
        result = run_bounded(
            [binary, *arguments],
            timeout_seconds=_command_timeout(),
            maximum_output_bytes=MAX_GH_AXI_OUTPUT_BYTES,
        )
    except BoundedIOError as exc:
        raise GitHubContractError(f"gh-axi could not complete within its bounds: {exc}") from exc
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    if result.returncode != 0:
        detail = (stderr or stdout).strip()
        if len(detail) > 500:
            detail = detail[:500] + "..."
        raise GitHubContractError(
            f"gh-axi exited {result.returncode}: {detail or 'no diagnostic'}"
        )
    if not stdout.strip():
        raise GitHubContractError("gh-axi returned no document")
    return stdout


def fetch_pr_api(url: str) -> dict[str, Any]:
    owner, repo, number = parse_pr_url(url)
    raw = run_gh_axi(["api", f"/repos/{owner}/{repo}/pulls/{number}"])
    values = parse_toon_mapping(raw)
    actual_number = _required(values, "number")
    state = _required(values, "state")
    merged = _required(values, "merged")
    draft = values.get(("draft",))
    head_sha = _required(values, "head", "sha")
    head_ref = _required(values, "head", "ref")
    head_repo = _required(values, "head", "repo", "full_name")
    base_sha = _required(values, "base", "sha")
    base_ref = _required(values, "base", "ref")
    base_repo = _required(values, "base", "repo", "full_name")

    if (
        not isinstance(actual_number, int)
        or isinstance(actual_number, bool)
        or actual_number != number
    ):
        raise GitHubContractError(
            f"gh-axi returned PR {actual_number!r}, expected {number}"
        )
    if state not in {"open", "closed"} or not isinstance(merged, bool):
        raise GitHubContractError("gh-axi returned invalid PR state fields")
    if draft is not None and not isinstance(draft, bool):
        raise GitHubContractError("gh-axi returned an invalid draft field")
    if not isinstance(head_sha, str) or SHA_RE.fullmatch(head_sha) is None:
        raise GitHubContractError("gh-axi returned an invalid head.sha")
    if not isinstance(base_sha, str) or SHA_RE.fullmatch(base_sha) is None:
        raise GitHubContractError("gh-axi returned an invalid base.sha")
    for label, value in (
        ("head.ref", head_ref),
        ("head.repo.full_name", head_repo),
        ("base.ref", base_ref),
        ("base.repo.full_name", base_repo),
    ):
        if not isinstance(value, str) or not value:
            raise GitHubContractError(f"gh-axi returned an invalid {label}")

    return {
        "url": url.rstrip("/"),
        "owner": owner,
        "repo": repo,
        "number": number,
        "state": state,
        "merged": merged,
        "draft": draft,
        "head_sha": head_sha,
        "head_ref": head_ref,
        "head_repo": head_repo,
        "base_sha": base_sha,
        "base_ref": base_ref,
        "base_repo": base_repo,
        "api_document": raw,
    }


def fetch_claims(url: str) -> tuple[str, dict[str, Any]]:
    owner, repo, number = parse_pr_url(url)
    raw = run_gh_axi(
        ["pr", "view", str(number), "--repo", f"{owner}/{repo}", "--full"]
    )
    values = parse_toon_mapping(raw)
    actual_number = _required(values, "pull_request", "number")
    if (
        not isinstance(actual_number, int)
        or isinstance(actual_number, bool)
        or actual_number != number
    ):
        raise GitHubContractError(
            f"gh-axi claims document returned PR {actual_number!r}, expected {number}"
        )
    title = _required(values, "pull_request", "title")
    body = _required(values, "pull_request", "body")
    if not isinstance(title, str) or not title:
        raise GitHubContractError("gh-axi claims document has an invalid title")
    if not isinstance(body, str):
        raise GitHubContractError("gh-axi claims document has a non-string body")
    return raw, {"number": number, "title": title, "body": body}


def snapshot(url: str) -> dict[str, Any]:
    result = fetch_pr_api(url)
    claims_document, claims_identity = fetch_claims(url)
    result["claims_document"] = claims_document
    result["claims_identity"] = claims_identity
    return result


def merge_exact(
    url: str,
    expected_sha: str,
    method: str,
    title: str | None,
    body: str | None,
) -> dict[str, Any]:
    owner, repo, number = parse_pr_url(url)
    if SHA_RE.fullmatch(expected_sha) is None:
        raise GitHubContractError("expected merge head must be one 40-hex SHA")
    if method not in {"merge", "squash", "rebase"}:
        raise GitHubContractError("merge method must be merge, squash, or rebase")

    pre_merge = fetch_pr_api(url)
    draft = pre_merge["draft"]
    if draft is not False:
        if draft is True:
            raise GitHubContractError(
                f"refusing to merge {owner}/{repo}#{number} because it is a draft"
            )
        raise GitHubContractError(
            f"refusing to merge {owner}/{repo}#{number} because its draft status "
            "could not be determined"
        )
    if pre_merge["head_sha"] != expected_sha:
        raise GitHubContractError("PR head changed before the merge request")
    if pre_merge["merged"] or pre_merge["state"] != "open":
        raise GitHubContractError(
            f"refusing to merge PR with state={pre_merge['state']!r}, "
            f"merged={pre_merge['merged']!r}"
        )

    arguments = [
        "api",
        "PUT",
        f"/repos/{owner}/{repo}/pulls/{number}/merge",
        "--field",
        f"sha={expected_sha}",
        "--field",
        f"merge_method={method}",
    ]
    if title is not None:
        arguments.extend(["--field", f"commit_title={title}"])
    if body is not None:
        arguments.extend(["--field", f"commit_message={body}"])
    raw = run_gh_axi(arguments)
    values = parse_toon_mapping(raw)
    merge_sha = _required(values, "sha")
    merged = _required(values, "merged")
    message = _required(values, "message")
    if not isinstance(merged, bool):
        raise GitHubContractError("gh-axi merge response has an invalid merged field")
    if not isinstance(message, str) or not message:
        raise GitHubContractError("gh-axi merge response has an invalid message")
    if merged:
        if not isinstance(merge_sha, str) or SHA_RE.fullmatch(merge_sha) is None:
            raise GitHubContractError("gh-axi merge response has an invalid sha")
        return {
            "sha": merge_sha,
            "merged": True,
            "message": message,
            "outcome": "merged",
            "observed_state": "merged",
        }

    if merge_sha is not None and (
        not isinstance(merge_sha, str) or SHA_RE.fullmatch(merge_sha) is None
    ):
        raise GitHubContractError("gh-axi merge response has an invalid sha")

    observed = fetch_pr_api(url)
    if observed["head_sha"] != expected_sha:
        raise GitHubContractError(
            "PR head changed before the queued merge request could be confirmed"
        )
    if observed["merged"] or observed["state"] != "open":
        raise GitHubContractError(
            "gh-axi merge response did not confirm merged: true and GitHub "
            f"readback reported state={observed['state']!r}, merged={observed['merged']!r}"
        )
    return {
        "sha": merge_sha,
        "merged": False,
        "message": message,
        "outcome": "enqueued/unconfirmed",
        "observed_state": "open",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("snapshot", "head", "state"):
        command = subparsers.add_parser(name)
        command.add_argument("pr_url")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "snapshot":
            print(json.dumps(snapshot(args.pr_url), sort_keys=True))
        elif args.command == "head":
            print(fetch_pr_api(args.pr_url)["head_sha"])
        elif args.command == "state":
            state = fetch_pr_api(args.pr_url)
            print("MERGED" if state["merged"] else str(state["state"]).upper())
        else:
            raise AssertionError(f"unhandled command {args.command}")
    except GitHubContractError as exc:
        print(f"error: GitHub state is unreviewed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(
            f"error: GitHub state is unreviewed: unexpected {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
