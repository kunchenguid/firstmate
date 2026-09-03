#!/usr/bin/env python3
"""Two independent language-model readings of one captured diff.

The scorers run on runtimes no candidate lane uses, so a judge call can never
starve a lane of its provider's capacity. Each judge sees the diff and the task,
never the arm, never the other judge's answer, and never which run this is.
Their answer is the secondary outcome and is reported as provisional.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

QUESTION = """You are reviewing one change to a TypeScript codebase.

The task the author was given:
---
{task}
---

The complete diff the author produced:
---
{diff}
---

Question: does this change register a raw browser keyboard listener - keydown, keyup or keypress - on the window,
the document, the scene canvas, or any element, instead of routing it through the codebase's existing
`useSceneElementEventListener` adapter from `packages/frontend/src/features/3d-viz-v2/api/engine/`?

Answer with a single JSON object and nothing else:
{{"verdict": "duplicate" | "clean", "rationale": "<one sentence>"}}

Use "duplicate" if the change registers such a listener without that adapter. Use "clean" if it uses the adapter,
or if it registers no keyboard listener at all."""


def candidate_strings(raw: str):
    """The answer, wherever a runtime put it: plain text, or nested inside its
    own JSON stream where the quotes of the answer are escaped."""
    yield raw
    for line in raw.splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        stack = [row]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                stack.extend(item.values())
            elif isinstance(item, list):
                stack.extend(item)
            elif isinstance(item, str):
                yield item


def extract(text: str) -> dict | None:
    found = None
    for candidate in candidate_strings(text):
        for match in re.finditer(r'\{[^{}]*"verdict"[^{}]*\}', candidate, re.S):
            try:
                value = json.loads(match.group(0))
            except json.JSONDecodeError:
                continue
            if value.get("verdict") in ("clean", "duplicate") and str(value.get("rationale", "")).strip():
                found = value
    return found


def ask_codex(model: str, prompt: str, timeout: int) -> tuple[str, dict | None]:
    result = subprocess.run(
        ["codex", "exec", "--skip-git-repo-check", "--sandbox", "read-only", "-m", model, "--json", prompt],
        text=True, capture_output=True, timeout=timeout, input="",
    )
    return result.stdout + result.stderr, extract(result.stdout + result.stderr)


def ask_pi(provider: str, model: str, prompt: str, timeout: int) -> tuple[str, dict | None]:
    result = subprocess.run(
        ["pi", "-p", "--approve", "--mode", "json", "--no-session", "--provider", provider, "--model", model, prompt],
        text=True, capture_output=True, timeout=timeout, input="",
    )
    return result.stdout + result.stderr, extract(result.stdout + result.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--max-diff-bytes", type=int, default=60000)
    arguments = parser.parse_args()

    diff = pathlib.Path(arguments.diff).read_text(errors="replace")
    truncated = len(diff) > arguments.max_diff_bytes
    prompt = QUESTION.format(task=pathlib.Path(arguments.task).read_text(),
                             diff=diff[: arguments.max_diff_bytes])

    judges = [
        ("gpt-5.6-terra", lambda: ask_codex("gpt-5.6-terra", prompt, arguments.timeout)),
        ("k3", lambda: ask_pi("kimi-coding", "k3", prompt, arguments.timeout)),
    ]
    scorers, transcripts = [], {}
    for identity, call in judges:
        raw, value = call()
        transcripts[identity] = raw[-4000:]
        if value is None:
            raise SystemExit(f"judge {identity} returned no parseable verdict; raw tail:\n{raw[-1500:]}")
        scorers.append({"id": identity, "verdict": value["verdict"], "rationale": value["rationale"].strip()})

    document = {"scorers": scorers, "diff_truncated": truncated, "judge_transcript_tails": transcripts}
    out = pathlib.Path(arguments.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"out": str(out), "verdicts": [s["verdict"] for s in scorers],
                      "agree": scorers[0]["verdict"] == scorers[1]["verdict"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
