#!/usr/bin/env python3
"""Offline CLI → parser → keyboard → rendered TUI regression check.

Run: python3 tests/pr_comments_smoke.py
The fixture gh only exists in this subprocess's PATH; no GitHub access is made.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def page(nodes, cursor=None):
    return {"nodes": nodes, "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor}}


def comment(identifier, body, hour="09"):
    return {"id": identifier, "body": body, "author": {"login": "reviewer"},
            "createdAt": f"2026-09-14T{hour}:00:00Z"}


def fixture(arguments):
    assert arguments[:2] == ["api", "graphql"], arguments
    fields = dict(argument.split("=", 1) for argument in arguments[2:] if "=" in argument)
    cursor = fields.get("endCursor")
    if cursor == "issues-next":
        return {"data": {"node": {"comments": page([comment("issue-last", "LAST ISSUE COMMENT")])}}}
    if cursor == "replies-next":
        return {"data": {"node": {"comments": page([comment("reply-last", "FINAL THREAD REPLY", "12")])}}}
    assert cursor is None, cursor
    assert fields["owner"] == "fixture" and fields["name"] == "comments" and fields["number"] == "42", fields
    replies = [comment(f"reply-{i}", f"Reply {i}: preserve every message", "11") for i in range(100)]
    replies[0].update(path="src/main.rs", line=42, diffHunk="@@ -40,3 +40,3 @@\n context\n context\n+retry()")
    return {"data": {"repository": {"pullRequest": {
        "id": "fixture-pr", "title": "Complete PR discussions", "body": "Fixture description",
        "author": {"login": "author"}, "mergeable": "MERGEABLE",
        "comments": page([comment(f"issue-{i}", f"Discussion message {i}") for i in range(100)], "issues-next"),
        "reviews": page([{"id": "review", "author": {"login": "reviewer"}, "state": "CHANGES_REQUESTED",
                          "body": "Please **retry failures**.\n\n- Preserve every response\n- Keep `timeout` visible",
                          "submittedAt": "2026-09-14T10:00:00Z"}]),
        "reviewThreads": page([{"id": "thread", "isResolved": True, "comments": page(replies, "replies-next")}]),
    }}}}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture-gh":
        print(json.dumps(fixture(sys.argv[2:])))
        return
    output = Path(tempfile.mkdtemp(prefix="vessel-pr-comments-"))
    fake_gh = output / "gh"
    fake_gh.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} --fixture-gh \"$@\"\n")
    fake_gh.chmod(0o755)
    env = dict(os.environ, PATH=f"{output}{os.pathsep}{os.environ['PATH']}", VESSEL_COMMENTS_SMOKE_DIR=str(output))
    subprocess.run(["cargo", "test", "cli_discussion_smoke", "--", "--ignored", "--nocapture"],
                   cwd=Path(__file__).resolve().parents[1], env=env, check=True)
    print(f"Verified 203 messages through the CLI and TUI. Rendered screens: {output}")


if __name__ == "__main__":
    main()
