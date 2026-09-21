#!/usr/bin/env python3
"""Reproducible coding benchmark for the machine-local Qwen EXL3 server.

Why this exists: the local model is meant to become an everyday coding
workhorse, so a tuning change has to be judged on both axes at once - how fast
it answers and how well it does real coding-shaped work. This harness runs a
small, deterministic suite against the loopback OpenAI endpoint and prints a
single comparable score line, so two server or provider configurations can be
diffed in minutes.

What it measures:

  * comprehension - locating a fact in a real repository, including one answer
    that only exists by joining several files.
  * patch - fixing a deliberately broken branch of a real script, where the
    score is that script's own committed test passing in an isolated copy.
  * tools - typed tool-call accuracy: requested functions, argument names and
    argument JSON types, across a two-step tool loop.
  * adherence - a strict output-format instruction with no room for prose.
  * longfile - reading a 2000+ line real file and reporting an exact subset.
  * refuse - a fact that does not exist anywhere, where the only correct
    answer is the instruction's own ABSENT sentinel.
  * speed - time to first token and steady-state decode rate, measured from
    streaming responses, plus prefill rate over long prompts.

Scoring is substring/sentinel based and file-based, never a model judging a
model. Every task records wall-clock seconds and output tokens so a quality
win that costs another 10x latency is visible rather than hidden.

Read-only against the real repository it cites; scratch writes only ever land
in the run's own temporary sandbox.

Usage:
    python3 bench.py --out results.json
    python3 bench.py --out results.json --thinking on --effort low
    python3 bench.py --out results.json --tasks comprehend_locate,speed
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

ENDPOINT = os.environ.get("QWEN_ENDPOINT", "http://127.0.0.1:8080")
MODEL = os.environ.get("QWEN_MODEL", "qwen3.8-27b")
API_KEY = os.environ.get("QWEN_API_KEY", "local")

# The real repository the comprehension, long-file, and patch tasks read.
# Read-only: nothing in this harness ever writes inside it.
REPO = Path(os.environ.get("QWEN_BENCH_REPO", "/home/umer/firstmate")).resolve()

READ_CHARS_PER_CALL = 40_000
SEARCH_MATCH_LIMIT = 60


# --------------------------------------------------------------------------
# transport
# --------------------------------------------------------------------------

def _post_stream(body: dict, timeout: float):
    """POST a chat completion and yield (kind, payload) decoded from SSE.

    Yields ("delta", str) for streamed assistant text, ("tool_calls", list)
    for streamed tool calls, ("usage", dict), ("finish", str), ("done", None).
    """
    parsed = urlsplit(ENDPOINT)
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port or 80, timeout=timeout)
    payload = json.dumps(body)
    conn.request(
        "POST",
        (parsed.path.rstrip("/") if parsed.path else "") + "/v1/chat/completions",
        body=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
            "Content-Length": str(len(payload.encode())),
        },
    )
    resp = conn.getresponse()
    if resp.status != 200:
        detail = resp.read().decode("utf-8", "replace")[:2000]
        conn.close()
        raise RuntimeError(f"HTTP {resp.status}: {detail}")
    pending_tool_calls: dict[int, dict] = {}
    try:
        while True:
            line = resp.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace").strip()
            if not text.startswith("data:"):
                continue
            data = text[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except json.JSONDecodeError:
                continue
            if isinstance(obj.get("usage"), dict):
                yield "usage", obj["usage"]
            choices = obj.get("choices") or []
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta") or {}
            if delta.get("content"):
                yield "delta", delta["content"]
            if delta.get("reasoning_content"):
                yield "reasoning", delta["reasoning_content"]
            for call in delta.get("tool_calls") or []:
                index = call.get("index", 0)
                slot = pending_tool_calls.setdefault(
                    index, {"id": call.get("id") or f"call_{index}", "type": "function",
                            "function": {"name": "", "arguments": ""}})
                if call.get("id"):
                    slot["id"] = call["id"]
                fn = call.get("function") or {}
                if fn.get("name"):
                    slot["function"]["name"] = fn["name"]
                if fn.get("arguments"):
                    slot["function"]["arguments"] += fn["arguments"]
            if choice.get("finish_reason"):
                if pending_tool_calls:
                    yield "tool_calls", [pending_tool_calls[k] for k in sorted(pending_tool_calls)]
                    pending_tool_calls = {}
                yield "finish", choice["finish_reason"]
    finally:
        conn.close()


def chat(messages, *, tools=None, max_tokens=4096, temperature=1.0, top_p=0.95,
         top_k=20, thinking=True, effort=None, timeout=600.0):
    """One streamed completion. Returns a dict with text, reasoning, calls, usage."""
    body = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
        "top_k": top_k,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": bool(thinking)},
    }
    if tools:
        body["tools"] = tools
    if thinking and effort:
        body["reasoning_effort"] = effort

    started = time.monotonic()
    first_token_at = None
    text_parts: list[str] = []
    reasoning_parts: list[str] = []
    calls: list[dict] = []
    usage: dict = {}
    finish = None
    for kind, value in _post_stream(body, timeout):
        if kind in ("delta", "reasoning"):
            if first_token_at is None:
                first_token_at = time.monotonic()
            if kind == "reasoning":
                reasoning_parts.append(value)
            else:
                text_parts.append(value)
        elif kind == "tool_calls":
            calls = value
        elif kind == "usage":
            usage = value
        elif kind == "finish":
            finish = value
    elapsed = time.monotonic() - started
    ttft = (first_token_at - started) if first_token_at else None
    completion = usage.get("completion_tokens") or 0
    decode = None
    if ttft is not None and completion > 1 and elapsed > ttft:
        decode = (completion - 1) / (elapsed - ttft)
    return {
        "text": "".join(text_parts),
        "reasoning": "".join(reasoning_parts),
        "calls": calls,
        "usage": usage,
        "finish": finish,
        "elapsed": elapsed,
        "ttft": ttft,
        "decode_tps": decode,
    }


# --------------------------------------------------------------------------
# sandbox tools handed to the model
# --------------------------------------------------------------------------

def _tool_schemas(sandbox: Path) -> list[dict]:
    return [
        {"type": "function", "function": {
            "name": "read_file",
            "description": "Read a text file from disk. Returns numbered lines.",
            "parameters": {"type": "object", "properties": {
                "path": {"type": "string", "description": "Absolute path"},
                "start_line": {"type": "integer", "description": "1-based first line"},
                "end_line": {"type": "integer", "description": "0 or omitted for end of file"},
            }, "required": ["path"]}}},
        {"type": "function", "function": {
            "name": "search_text",
            "description": ("Search files under a directory for a literal string. "
                            "Returns path:line: text matches."),
            "parameters": {"type": "object", "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string", "description": "Directory or file to search"},
                "include": {"type": "string", "description": "Filename suffix filter, e.g. .sh"},
            }, "required": ["pattern"]}}},
        {"type": "function", "function": {
            "name": "replace_text",
            "description": ("Replace the first exact occurrence of old_text in a file. "
                            "Only paths inside the task sandbox are writable."),
            "parameters": {"type": "object", "properties": {
                "path": {"type": "string"},
                "old_text": {"type": "string"},
                "new_text": {"type": "string"},
            }, "required": ["path", "old_text", "new_text"]}}},
        {"type": "function", "function": {
            "name": "write_file",
            "description": "Overwrite a file with new content. Sandbox paths only.",
            "parameters": {"type": "object", "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            }, "required": ["path", "content"]}}},
    ]


def _resolve_read(raw: str, sandbox: Path) -> Path:
    """Relative read paths resolve against the sandbox, then the repository."""
    path = Path(raw)
    if path.is_absolute():
        return path
    if (sandbox / path).exists():
        return sandbox / path
    return REPO / path


def _resolve_write(raw: str, sandbox: Path) -> Path:
    """Relative write paths always resolve inside the sandbox."""
    path = Path(raw)
    return path if path.is_absolute() else sandbox / path


def _readable(path: Path) -> bool:
    try:
        return REPO in path.resolve().parents or path.resolve() == REPO
    except OSError:
        return False


def _writable(path: Path, sandbox: Path) -> bool:
    try:
        return sandbox.resolve() in path.resolve().parents
    except OSError:
        return False


def _exec_tool(name: str, args: dict, sandbox: Path) -> str:
    try:
        if name == "read_file":
            target = _resolve_read(str(args.get("path", "")), sandbox)
            if not _readable(target) and not _writable(target, sandbox):
                return f"error: path outside the readable repository: {target}"
            if not target.is_file():
                return f"error: no such file: {target}"
            lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
            start = max(1, int(args.get("start_line") or 1))
            end = int(args.get("end_line") or 0) or len(lines)
            end = min(end, len(lines))
            out, used = [], 0
            for number in range(start, end + 1):
                row = f"{number}\t{lines[number - 1]}"
                used += len(row) + 1
                if used > READ_CHARS_PER_CALL:
                    out.append("... output truncated, call again with a higher start_line")
                    break
                out.append(row)
            return "\n".join(out) or "error: empty range"
        if name == "search_text":
            pattern = str(args.get("pattern", ""))
            if not pattern:
                return "error: pattern is required"
            root = Path(str(args.get("path") or REPO))
            if not root.is_absolute():
                root = REPO / root
            if root.is_file():
                candidates = [root]
            else:
                suffix = str(args.get("include") or "")
                candidates = [p for p in sorted(root.rglob(f"*{suffix}")) if p.is_file()]
            hits = []
            for candidate in candidates:
                if ".." in candidate.parts or candidate.is_symlink():
                    continue
                if not _readable(candidate) and not _writable(candidate, sandbox):
                    continue
                try:
                    body = candidate.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                for number, line in enumerate(body.splitlines(), 1):
                    if pattern in line:
                        hits.append(f"{candidate}:{number}: {line.strip()[:200]}")
                        if len(hits) >= SEARCH_MATCH_LIMIT:
                            return "\n".join(hits) + "\n... more matches truncated"
            return "\n".join(hits) or "no matches"
        if name == "replace_text":
            target = _resolve_write(str(args.get("path", "")), sandbox)
            if not _writable(target, sandbox):
                return f"error: not writable (sandbox paths only): {target}"
            old = str(args.get("old_text", ""))
            new = str(args.get("new_text", ""))
            if not old:
                return "error: old_text is required"
            body = target.read_text(encoding="utf-8")
            if body.count(old) != 1:
                return f"error: old_text occurs {body.count(old)} times, need exactly 1"
            target.write_text(body.replace(old, new, 1), encoding="utf-8")
            return "ok: replaced 1 occurrence"
        if name == "write_file":
            target = _resolve_write(str(args.get("path", "")), sandbox)
            if not _writable(target, sandbox):
                return f"error: not writable (sandbox paths only): {target}"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(str(args.get("content", "")), encoding="utf-8")
            return "ok: wrote file"
    except Exception as exc:  # noqa: BLE001 - the model must see failures as text
        return f"error: {type(exc).__name__}: {exc}"
    return f"error: unknown tool {name}"


# --------------------------------------------------------------------------
# tasks
# --------------------------------------------------------------------------

SYSTEM = (
    "You are a coding assistant working on files on this machine. "
    "Use the provided tools to look things up instead of guessing. "
    "When you have the answer, reply with it and no tool call."
)

TASKS: dict[str, dict] = {}


def task(name):
    def wrap(fn):
        TASKS[name] = fn()
        return fn
    return wrap


@task("comprehend_locate")
def _t_locate():
    return {
        "kind": "locate",
        "prompt": ("Which single file under {repo}/bin defines the shell function "
                   "`fm_afk_mode`? Answer with just the file name, for example `foo.sh`."
                   ).format(repo=REPO),
        "expect_any": ["fm-wake-lib.sh"],
        "expect_regex": [r"fm-wake-lib\.sh"],
        "max_tokens": 3072,
    }


@task("comprehend_cross")
def _t_cross():
    return {
        "kind": "locate",
        "prompt": ("Search {repo}/bin for the literal string `branch-outcomes.jsonl`. "
                   "Which distinct files under bin/ contain it? Answer with the file "
                   "names only, comma separated, in alphabetical order."
                   ).format(repo=REPO),
        "expect_all": ["fm-afk-return.sh", "fm-branch-outcome.sh", "fm-wake-drain.sh"],
        "max_tokens": 4096,
    }


@task("longfile")
def _t_longfile():
    return {
        "kind": "locate",
        "prompt": ("Read {repo}/bin/fm-classify-lib.sh, a long shell library. "
                   "List, in file order, the names of the top-level shell functions "
                   "defined in it whose names begin with `status_is_`. "
                   "Answer with the names only, comma separated, nothing else."
                   ).format(repo=REPO),
        "expect_all": ["status_is_terminal_verb", "status_is_captain_relevant",
                       "status_is_paused", "status_is_captain_held",
                       "status_is_paused_or_captain_held"],
        "forbid_any": ["status_is_unknown", "status_is_working", "status_is_done",
                       "status_is_open"],
        "max_tokens": 4096,
    }


@task("adherence")
def _t_adherence():
    return {
        "kind": "text",
        "prompt": ("Reply with exactly one JSON object and nothing else. "
                   "It must have exactly these three keys: `task` with the string value "
                   "`probe`, `count` with the integer value 3, and `ok` with the boolean "
                   "value true. No code fence, no prose."),
        "check": "strict_json",
        "expect_json": {"task": "probe", "count": 3, "ok": True},
        "max_tokens": 3072,
    }


@task("refuse")
def _t_refuse():
    return {
        "kind": "text",
        "prompt": ("What is the value of the shell variable `FM_WATCH_POLL_INTERVAL_MS` "
                   "in {repo}/bin/fm-watch.sh? Reply with the value only, or the single "
                   "word ABSENT if that variable is not defined in that file."
                   ).format(repo=REPO),
        "check": "sentinel_absent",
        "expect_regex": [r"\bABSENT\b"],
        "forbid_regex": [r"\b\d{2,}\b"],
        "max_tokens": 3072,
    }


@task("tools")
def _t_tools():
    return {
        "kind": "tools",
        "prompt": (
            "Call the function `open_pane` exactly once with pane_id `wG:pQ`, "
            "workspace `wG`, index 7 and focused false. Then, after the tool result, "
            "call the function `set_limits` exactly once with limits.max_tokens 4096, "
            "limits.temperature 0.25, tags [\"a\",\"b\"] and label \"007\"."),
        "max_tokens": 3072,
    }


TOOL_TASK_TOOLS = [
    {"type": "function", "function": {
        "name": "open_pane",
        "description": "Open a pane in a workspace.",
        "parameters": {"type": "object", "properties": {
            "pane_id": {"type": "string"},
            "workspace": {"type": "string"},
            "index": {"type": "integer"},
            "focused": {"type": "boolean"},
        }, "required": ["pane_id", "workspace", "index", "focused"]}}},
    {"type": "function", "function": {
        "name": "set_limits",
        "description": "Set limits for a session.",
        "parameters": {"type": "object", "properties": {
            "limits": {"type": "object", "properties": {
                "max_tokens": {"type": "integer"},
                "temperature": {"type": "number"},
            }, "required": ["max_tokens", "temperature"]},
            "tags": {"type": "array", "items": {"type": "string"}},
            "label": {"type": "string"},
        }, "required": ["limits", "tags", "label"]}}},
]


PATCH_FILES = ("bin/fm-transition-lib.sh", "tests/lib.sh", "tests/git-config-helpers.sh",
               "tests/fm-transition-lib.test.sh")
PATCH_BROKEN = "    blocked) printf 'absorb' ;;"
PATCH_CORRECT = "    blocked) printf 'actionable' ;;"


@task("patch")
def _t_patch():
    return {
        "kind": "patch",
        "prompt": (
            "The isolated copy of the firstmate repository at {sandbox} has a broken "
            "unit test. Run nothing; instead read the code and fix the defect so the "
            "behavior matches what the code's own documentation says the policy table "
            "must do. The test to satisfy is {sandbox}/tests/fm-transition-lib.test.sh. "
            "Stay inside {sandbox}."),
        "max_tokens": 6144,
    }


# --------------------------------------------------------------------------
# scoring
# --------------------------------------------------------------------------

def _normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def score_locate(spec: dict, result: dict) -> tuple[bool, str]:
    answer = _normalized(result["text"])
    for pattern in spec.get("expect_regex", []):
        if not re.search(pattern, answer):
            return False, f"missing required pattern {pattern!r}"
    for needle in spec.get("expect_all", []):
        if needle not in answer:
            return False, f"missing required value {needle!r}"
    for needle in spec.get("forbid_any", []):
        if needle in answer:
            return False, f"contains forbidden value {needle!r}"
    if not spec.get("expect_regex") and not spec.get("expect_all"):
        return False, "task has no scoring criteria"
    return True, "ok"


def score_text(spec: dict, result: dict) -> tuple[bool, str]:
    raw = result["text"].strip()
    if spec["check"] == "strict_json":
        body = raw
        fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", raw, re.S)
        if fence:
            return False, "wrapped the JSON in a code fence"
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError as exc:
            return False, f"not valid JSON: {exc}"
        if parsed != spec["expect_json"]:
            return False, f"wrong object: {parsed!r}"
        return True, "ok"
    if spec["check"] == "sentinel_absent":
        for pattern in spec.get("expect_regex", []):
            if not re.search(pattern, raw, re.I):
                return False, f"did not answer the sentinel ({pattern!r})"
        for pattern in spec.get("forbid_regex", []):
            if re.search(pattern, raw):
                return False, f"invented a value matching {pattern!r}: {raw[:200]!r}"
        return True, "ok"
    return False, f"unknown check {spec['check']!r}"


def score_tools(spec: dict, result: dict, calls: list[dict]) -> tuple[bool, str]:
    if len(calls) != 2:
        return False, f"expected 2 tool calls, saw {len(calls)}"
    try:
        first = {"name": calls[0]["function"]["name"],
                 "args": json.loads(calls[0]["function"]["arguments"])}
        second = {"name": calls[1]["function"]["name"],
                  "args": json.loads(calls[1]["function"]["arguments"])}
    except (KeyError, json.JSONDecodeError) as exc:
        return False, f"unparseable tool call: {exc}"
    if first["name"] != "open_pane":
        return False, f"first call was {first['name']!r}"
    if first["args"] != {"pane_id": "wG:pQ", "workspace": "wG", "index": 7, "focused": False}:
        return False, f"open_pane arguments wrong: {first['args']!r}"
    if second["name"] != "set_limits":
        return False, f"second call was {second['name']!r}"
    want = {"limits": {"max_tokens": 4096, "temperature": 0.25},
            "tags": ["a", "b"], "label": "007"}
    if second["args"] != want:
        return False, f"set_limits arguments wrong: {second['args']!r}"
    return True, "ok"


def score_patch(spec: dict, sandbox: Path) -> tuple[bool, str]:
    test = sandbox / "tests/fm-transition-lib.test.sh"
    proc = subprocess.run(
        ["bash", str(test)], cwd=str(sandbox), capture_output=True, text=True, timeout=180)
    if proc.returncode == 0 and "all assertions passed" in proc.stdout:
        return True, "ok"
    tail = (proc.stdout + proc.stderr).strip().splitlines()[-4:]
    return False, "test failed: " + " | ".join(tail)


# --------------------------------------------------------------------------
# runner
# --------------------------------------------------------------------------

def prepare_sandbox(root: Path) -> Path:
    sandbox = root / "patch"
    for relative in PATCH_FILES:
        destination = sandbox / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / relative, destination)
    library = sandbox / "bin/fm-transition-lib.sh"
    body = library.read_text(encoding="utf-8")
    if PATCH_CORRECT not in body:
        raise RuntimeError("patch fixture does not contain the expected policy line")
    library.write_text(body.replace(PATCH_CORRECT, PATCH_BROKEN, 1), encoding="utf-8")
    return sandbox


def run_task(name: str, spec: dict, root: Path, args) -> dict:
    sandbox = prepare_sandbox(root) if spec["kind"] == "patch" else root / "scratch"
    sandbox.mkdir(parents=True, exist_ok=True)
    tools = TOOL_TASK_TOOLS if spec["kind"] == "tools" else _tool_schemas(sandbox)
    prompt = spec["prompt"].format(repo=REPO, sandbox=sandbox)
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]

    record = {"task": name, "kind": spec["kind"], "steps": 0, "seconds": 0.0,
              "output_tokens": 0, "tool_calls": 0, "tool_errors": []}
    started = time.monotonic()
    final_text = ""
    all_calls: list[dict] = []
    try:
        for step in range(args.max_steps):
            record["steps"] = step + 1
            reply = chat(messages, tools=tools, max_tokens=spec["max_tokens"],
                         temperature=args.temperature, top_p=args.top_p, top_k=args.top_k,
                         thinking=args.thinking, effort=args.effort, timeout=args.timeout)
            record["output_tokens"] += reply["usage"].get("completion_tokens") or 0
            if reply["calls"]:
                all_calls.extend(reply["calls"])
                record["tool_calls"] += len(reply["calls"])
                messages.append({"role": "assistant", "content": reply["text"],
                                 "tool_calls": reply["calls"]})
                for call in reply["calls"]:
                    fn = call.get("function") or {}
                    try:
                        arguments = json.loads(fn.get("arguments") or "{}")
                    except json.JSONDecodeError as exc:
                        arguments = {}
                        output = f"error: arguments were not valid JSON: {exc}"
                    else:
                        output = (_exec_tool(fn.get("name", ""), arguments, sandbox)
                                  if spec["kind"] != "tools"
                                  else "ok: recorded for scoring")
                    if output.startswith("error:"):
                        record["tool_errors"].append(output[:200])
                    messages.append({"role": "tool", "tool_call_id": call.get("id", ""),
                                     "content": output})
                if spec["kind"] == "tools" and len(all_calls) >= 2:
                    break
                continue
            final_text = reply["text"]
            break
    except Exception as exc:  # noqa: BLE001 - a transport failure is a result too
        record["error"] = f"{type(exc).__name__}: {exc}"
    record["seconds"] = round(time.monotonic() - started, 2)
    record["final_text"] = final_text[:4000]

    if spec["kind"] in ("locate",):
        passed, why = score_locate(spec, {"text": _normalized(final_text)})
    elif spec["kind"] in ("text",):
        passed, why = score_text(spec, {"text": final_text})
    elif spec["kind"] == "tools":
        passed, why = score_tools(spec, {"text": final_text}, all_calls)
    elif spec["kind"] == "patch":
        passed, why = score_patch(spec, sandbox)
    else:
        passed, why = False, f"unknown kind {spec['kind']}"
    record["passed"] = passed
    record["reason"] = why
    return record


SPEED_PROMPT = (
    "Write a bash function `fm_collect_ids` that reads lines from stdin, trims "
    "surrounding whitespace, drops empty lines and lines starting with '#', "
    "deduplicates while preserving first-seen order, and prints the result "
    "one per line. Then write a second function `fm_join_ids` that takes the "
    "same input and prints it comma separated on one line. Include short "
    "comments. Reply with the code only."
)

PREFILL_FILLERS = [
    "the watcher polls the session endpoint and records each observed transition",
    "a durable queue keeps every wake until the handling turn acknowledges it",
    "the backend adapter normalises status names before policy runs over them",
    "each check script prints one line only when firstmate should be woken",
]


def build_long_prompt(index: int, target_words: int = 4000) -> str:
    """A distinct, mostly-incompressible long prompt for prefill measurement."""
    lines = []
    counter = index * 1_000_003
    while len(lines) < target_words:
        counter = (counter * 1103515245 + 12345) % (2 ** 31)
        filler = PREFILL_FILLERS[counter % len(PREFILL_FILLERS)]
        lines.append(f"note {counter:010d}: {filler}")
    body = "\n".join(lines)
    return (f"Below is a numbered engineering log. Count how many lines mention "
            f"`prefill`.\n\n{body}\n\nReply with the single integer only.")


def run_speed(args, root: Path, repeats: int = 3) -> dict:
    # Warm-up first: the first request after an idle period runs at lower SM
    # clocks and would otherwise land in the median as a phantom regression.
    chat([{"role": "user", "content": "Say ok."}], max_tokens=8,
         thinking=False, timeout=args.timeout)
    time.sleep(3)
    samples = []
    for index in range(repeats):
        prompt = build_long_prompt(index) if args.long_prompts else SPEED_PROMPT
        reply = chat([{"role": "user", "content": prompt}], max_tokens=args.speed_max_tokens,
                     temperature=args.temperature, top_p=args.top_p, top_k=args.top_k,
                     thinking=args.speed_thinking, effort=args.effort, timeout=args.timeout)
        samples.append({
            "index": index,
            "prompt_tokens": reply["usage"].get("prompt_tokens") or 0,
            "completion_tokens": reply["usage"].get("completion_tokens") or 0,
            "ttft_s": round(reply["ttft"], 4) if reply["ttft"] else None,
            "total_s": round(reply["elapsed"], 3),
            "decode_tps": round(reply["decode_tps"], 2) if reply["decode_tps"] else None,
            "finish": reply["finish"],
        })
    decodes = sorted(s["decode_tps"] for s in samples if s["decode_tps"])
    ttfts = sorted(s["ttft_s"] for s in samples if s["ttft_s"])
    prefill = []
    for sample in samples:
        if sample["ttft_s"] and sample["prompt_tokens"]:
            prefill.append(sample["prompt_tokens"] / sample["ttft_s"])
    return {
        "repeats": repeats,
        "decode_tps_median": decodes[len(decodes) // 2] if decodes else None,
        "ttft_s_median": ttfts[len(ttfts) // 2] if ttfts else None,
        "prefill_tps_median": round(sorted(prefill)[len(prefill) // 2], 1) if prefill else None,
        "samples": samples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="results JSON path")
    parser.add_argument("--label", default="", help="label recorded in the results")
    parser.add_argument("--tasks", default=",".join(TASKS) + ",speed",
                        help="comma separated task names, or 'all'")
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--top-k", type=int, default=20)
    parser.add_argument("--thinking", choices=["on", "off"], default="on")
    parser.add_argument("--speed-thinking", choices=["on", "off"], default="off",
                        help="thinking mode for the speed probe; off isolates the server config")
    parser.add_argument("--effort", choices=["low", "medium", "xhigh"], default=None)
    parser.add_argument("--max-steps", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--speed-max-tokens", type=int, default=700)
    parser.add_argument("--speed-repeats", type=int, default=5)
    parser.add_argument("--long-prompts", action="store_true",
                        help="measure prefill with long distinct prompts instead of decode")
    parser.add_argument("--speed-only", action="store_true")
    parser.add_argument("--tasks-only", action="store_true")
    args = parser.parse_args()
    args.thinking = args.thinking == "on"
    args.speed_thinking = args.speed_thinking == "on"

    wanted = list(TASKS) if args.tasks == "all" else [t.strip() for t in args.tasks.split(",") if t.strip()]
    for name in wanted:
        if name != "speed" and name not in TASKS:
            parser.error(f"unknown task {name!r}")

    results = {
        "label": args.label,
        "when": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "endpoint": ENDPOINT,
        "model": MODEL,
        "settings": {
            "temperature": args.temperature, "top_p": args.top_p, "top_k": args.top_k,
            "thinking": args.thinking, "effort": args.effort,
            "speed_thinking": args.speed_thinking,
            "speed_max_tokens": args.speed_max_tokens,
        },
        "tasks": {},
    }

    with tempfile.TemporaryDirectory(prefix="qwen-bench-") as tmp:
        root = Path(tmp)
        if not args.speed_only:
            for name in wanted:
                if name == "speed":
                    continue
                record = run_task(name, TASKS[name], root, args)
                results["tasks"][name] = record
                flag = "PASS" if record["passed"] else "FAIL"
                print(f"[{flag}] {name:20s} {record['seconds']:6.1f}s "
                      f"{record['output_tokens']:5d} tok  {record['reason']}", flush=True)
        if not args.tasks_only and "speed" in wanted:
            speed = run_speed(args, root, args.speed_repeats)
            results["speed"] = speed
            print(f"[speed] decode {speed['decode_tps_median']} tok/s  "
                  f"ttft {speed['ttft_s_median']}s  prefill {speed['prefill_tps_median']} tok/s",
                  flush=True)

    scored = [r for r in results["tasks"].values() if "passed" in r]
    results["summary"] = {
        "passed": sum(1 for r in scored if r["passed"]),
        "total": len(scored),
        "quality_score": (sum(1 for r in scored if r["passed"]) / len(scored)) if scored else None,
        "total_seconds": round(sum(r["seconds"] for r in scored), 1),
    }
    Path(args.out).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(results["summary"]), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
