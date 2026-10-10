#!/usr/bin/env python3
"""Optional local text drafts: commit-msg [--repo PATH] or summarise-log [FILE].

Read config/local-llm.json from FM_CONFIG_OVERRIDE, FM_HOME, or this repo.
The JSON file contains base_url and model. No network request is made without it.
Output is written only after a complete, valid response has been received.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


MAX_INPUT = 100_000  # Well below a 64k-token context, including the prompt.
TIMEOUT = 5
TRIM_MARKER = "\n[INPUT TRIMMED TO FIT LOCAL MODEL CONTEXT]\n"


def fail(reason):
    print(f"fm-local-llm: {reason}", file=sys.stderr)
    return 1


def config_path():
    root = Path(__file__).resolve().parent.parent
    return Path(os.environ.get("FM_CONFIG_OVERRIDE") or
                Path(os.environ.get("FM_HOME", root)) / "config") / "local-llm.json"


def load_config():
    path = config_path()
    if not path.is_file():
        raise ValueError(f"missing {path}; set base_url and model in config/local-llm.json")
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
        base_url, model = config["base_url"], config["model"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ValueError(f"invalid {path}: {exc}") from exc
    if not isinstance(base_url, str) or not isinstance(model, str) or not model.strip():
        raise ValueError(f"invalid {path}: base_url and model must be strings")
    parsed = urlsplit(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError(f"invalid {path}: base_url must be an HTTP(S) API root")
    return base_url.rstrip("/") + "/chat/completions", model


def bounded(text, tail=False):
    if len(text) <= MAX_INPUT:
        return text
    keep = MAX_INPUT - len(TRIM_MARKER)
    if tail:
        return TRIM_MARKER + text[-keep:]
    return text[:keep // 2] + TRIM_MARKER + text[-(keep - keep // 2):]


def request_completion(url, model, task, source):
    if task == "commit-msg":
        instruction = ("Draft a conventional commit message from this staged diff. "
                       "First line: type(scope): summary, under 72 characters. "
                       "Then a blank line and at most three short body lines. "
                       "Describe only changes supported by the diff. "
                       "The diff may be trimmed; do not guess omitted details.")
    else:
        instruction = ("Summarise this test or CI log in at most five bullet lines. "
                       "Say which tests failed, the most likely cause, and the first file to inspect when supported. "
                       "If nothing failed, say plainly that nothing failed. "
                       "Do not invent failures or facts absent from the log. "
                       "The log may contain only its tail.")
    payload = {"model": model, "messages": [
        {"role": "system", "content": instruction},
        {"role": "user", "content": source}],
        "chat_template_kwargs": {"enable_thinking": False},
        "stream": False, "max_tokens": 300}
    req = Request(url, data=json.dumps(payload).encode("utf-8"),
                  headers={"Content-Type": "application/json"}, method="POST")
    with urlopen(req, timeout=TIMEOUT) as response:
        result = json.load(response)
    content = result["choices"][0]["message"]["content"]
    if not isinstance(content, str):
        raise ValueError("model returned no text")
    return content.strip()


def validate(task, content):
    if not content:
        raise ValueError("model returned empty text")
    lines = content.splitlines()
    if task == "commit-msg":
        if not re.fullmatch(r"(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\([^)\n]+\))?!?: .+", lines[0]) or len(lines[0]) >= 72:
            raise ValueError("model returned an invalid commit subject")
        if len(lines) > 1 and (lines[1] != "" or len(lines[2:]) > 3 or any(not line.strip() for line in lines[2:])):
            raise ValueError("model returned an invalid commit body")
    else:
        bullets = [re.fullmatch(r"[-*•][ \t]+(.+)", line) for line in lines]
        if len(lines) > 5 or any(not bullet or not bullet[1].strip() for bullet in bullets):
            raise ValueError("model returned an invalid log summary")
        return "\n".join(f"- {bullet[1].strip()}" for bullet in bullets)
    return content


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="task", required=True)
    commit = commands.add_parser("commit-msg", help="draft from stdin or a repo's staged diff")
    commit.add_argument("--repo", help="repository with a staged diff")
    summary = commands.add_parser("summarise-log", help="summarise a log file or stdin")
    summary.add_argument("file", nargs="?", help="log file; default stdin")
    args = parser.parse_args()
    try:
        url, model = load_config()
        if args.task == "commit-msg" and args.repo:
            source = subprocess.run(["git", "-C", args.repo, "diff", "--cached", "--no-ext-diff"],
                                    check=True, capture_output=True, text=True).stdout
        elif args.task == "summarise-log" and args.file and args.file != "-":
            source = Path(args.file).read_text(encoding="utf-8", errors="replace")
        else:
            source = sys.stdin.read()
        if not source.strip():
            raise ValueError("input is empty")
        result = validate(args.task, request_completion(url, model, args.task,
                                                        bounded(source, args.task == "summarise-log")))
    except HTTPError as exc:
        return fail(f"endpoint returned HTTP {exc.code}")
    except (URLError, TimeoutError) as exc:
        return fail(f"endpoint unavailable or timed out: {exc.reason if isinstance(exc, URLError) else exc}")
    except subprocess.CalledProcessError:
        return fail("could not read staged diff")
    except (OSError, ValueError, KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        return fail(str(exc).replace("\n", " "))
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
