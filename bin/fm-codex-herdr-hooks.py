#!/usr/bin/env python3
# Session hook selection implementation; fm-codex-herdr-hooks.sh owns usage.
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import re
import subprocess
import sys
import time

VERSION = "codex-cli 0.164.0"
FIELDS = {"mode", "codexVersion", "hookKey", "hookHash", "integrationPath", "integrationSha256"}


def refuse(message):
    raise ValueError(message)


def inventory(binary, cwd, flags):
    # No thread/start, turn/start, config writes, or hook invocation.
    process = subprocess.Popen(
        [binary, "--enable", "hooks", *flags, "app-server", "--stdio"],
        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = bytearray()
    deadline = time.monotonic() + 25

    def request(identifier, method, params):
        process.stdin.write((json.dumps({"id": identifier, "method": method, "params": params}) + "\n").encode())
        process.stdin.flush()
        while time.monotonic() < deadline:
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                pending[:] = rest
                response = json.loads(line)
                if response.get("id") == identifier:
                    if "error" in response or "result" not in response:
                        refuse(f"Codex {method} refused the inventory request")
                    return response["result"]
            if not selector.select(min(1, max(0, deadline - time.monotonic()))):
                continue
            data = os.read(process.stdout.fileno(), 65536)
            if not data:
                refuse("Codex closed the inventory transport")
            pending.extend(data)
            if len(pending) > 16 * 1024 * 1024:
                refuse("Codex inventory exceeded the response bound")
        refuse("Codex inventory timed out after 25 seconds")

    try:
        initialized = request(1, "initialize", {
            "clientInfo": {"name": "firstmate_hook_inventory", "version": "1"},
            "capabilities": {"experimentalApi": True},
        })
        home = Path(initialized["codexHome"])
        if not home.is_absolute():
            refuse("Codex returned a relative home")
        requirements = request(2, "configRequirements/read", None)
        if "requirements" not in requirements:
            refuse("Codex omitted managed requirements")
        policy = requirements["requirements"]
        if policy is not None and (not isinstance(policy, dict) or policy.get("hooks") is not None):
            refuse("managed hook policy cannot be isolated by session flags")
        if policy is not None and "hooks" in (policy.get("featureRequirements") or {}):
            refuse("managed hook feature requirements are unsupported by this selector")
        result = request(3, "hooks/list", {"cwds": [str(cwd)]})
        if not isinstance(result.get("data"), list) or len(result["data"]) != 1:
            refuse("ambiguous Codex hook inventory")
        entry = result["data"][0]
        if entry.get("cwd") != str(cwd) or entry.get("warnings") != [] or entry.get("errors") != []:
            refuse("Codex hook inventory has warnings, errors, or a mismatched cwd")
        hooks = entry.get("hooks")
        if not isinstance(hooks, list) or not hooks:
            refuse("Codex returned no hook inventory")
        keys = set()
        for hook in hooks:
            if not isinstance(hook, dict):
                refuse("malformed hook inventory entry")
            key = hook.get("key")
            if not isinstance(key, str) or not key or key in keys:
                refuse("missing or duplicate hook key")
            keys.add(key)
            if hook.get("isManaged") is not False or hook.get("source") not in {"user", "project", "plugin"}:
                refuse("managed or unknown hook source cannot be isolated")
            if hook.get("trustStatus") not in {"trusted", "untrusted", "modified"}:
                refuse("unknown hook trust state")
            if type(hook.get("enabled")) is not bool or not isinstance(hook.get("currentHash"), str):
                refuse("incomplete hook state")
        return home, hooks
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdin.close()
        process.stdout.close()


def selected(home, hooks):
    script = home / "herdr-agent-state.sh"
    content = script.read_bytes()
    if b"# HERDR_INTEGRATION_ID=codex\n" not in content or b"# HERDR_INTEGRATION_VERSION=10\n" not in content:
        refuse("expected the installed Herdr Codex integration v10")
    matches = []
    for hook in hooks:
        if (hook.get("source") == "user" and hook.get("sourcePath") == str(home / "hooks.json")
                and hook.get("eventName") == "sessionStart" and hook.get("handlerType") == "command"
                and hook.get("matcher") in {None, ""} and hook.get("async") is False):
            # Compare arguments without executing any shell from the inventory.
            if shlex.split(hook.get("command", "")) == ["bash", str(script), "session"]:
                matches.append(hook)
    if len(matches) != 1:
        refuse("expected exactly one installed Herdr SessionStart hook in user hooks.json")
    hook = matches[0]
    return hook, {
        "mode": "herdr-only", "codexVersion": VERSION,
        "hookKey": hook["key"], "hookHash": hook["currentHash"],
        "integrationPath": str(script), "integrationSha256": hashlib.sha256(content).hexdigest(),
    }


def main():
    args = sys.argv[1:]
    action = args.pop(0) if args else ""
    if action == "review" and len(args) == 1:
        cwd, review_path, launch = Path(args[0]).resolve(strict=True), None, []
    elif action == "check" and len(args) == 2:
        review_path, cwd, launch = Path(args[0]), Path(args[1]).resolve(strict=True), []
    elif action == "exec" and len(args) >= 2 and args[1] == "--":
        review_path, cwd, launch = Path(args[0]), Path.cwd().resolve(), args[2:]
        if os.environ.get("HERDR_ENV") != "1" or not os.environ.get("HERDR_PANE_ID") or not os.environ.get("HERDR_SOCKET_PATH"):
            refuse("Herdr task pane routing is missing")
        # fm-spawn supplies only model, effort, approval, notify and prompt.
        # Reject all other selectors, including short/equal forms and cwd flags.
        index = 0
        notifications = 0
        while index < len(launch) - 1:
            arg = launch[index]
            if arg in {"-m", "--model"} and index + 1 < len(launch) - 1:
                index += 2
            elif arg == "-c" and index + 1 < len(launch) - 1:
                value = launch[index + 1]
                if value.startswith("notify="):
                    notify = json.loads(value[len("notify="):])
                    if (not isinstance(notify, list) or len(notify) != 3
                            or notify[:2] != ["bash", "-c"] or not isinstance(notify[2], str)
                            or not notify[2].startswith("touch ")):
                        refuse("expected Firstmate's independent turn-end notify program")
                    notifications += 1
                elif not re.fullmatch(r'model_reasoning_effort="(minimal|low|medium|high|xhigh|max)"', value):
                    refuse("unexpected config value in Codex launch arguments")
                index += 2
            elif arg in {"--dangerously-bypass-approvals-and-sandbox", "--approve-for-me"}:
                index += 1
            elif arg == "--sandbox" and launch[index + 1:index + 2] == ["workspace-write"]:
                index += 2
            elif arg == "--ask-for-approval" and launch[index + 1:index + 2] == ["on-request"]:
                index += 2
            else:
                refuse("unexpected selector in Codex launch arguments")
        if not launch or index != len(launch) - 1 or launch[-1].startswith("-"):
            refuse("expected the normal Firstmate task prompt")
        if notifications != 1:
            refuse("expected exactly one Firstmate turn-end notify override")
    else:
        refuse("usage: review <cwd> | check <review.json> <cwd> | exec <review.json> -- <codex-arguments...>")
    if not cwd.is_dir():
        refuse("task cwd is not a directory")
    binary = shutil.which("codex")
    if not binary:
        refuse("codex is unavailable")
    version = subprocess.run([binary, "--version"], check=True, capture_output=True, text=True, timeout=5).stdout.strip()
    if version != VERSION:
        refuse(f"unsupported Codex version: {version}; expected {VERSION}")
    home, hooks = inventory(binary, cwd, [])
    hook, candidate = selected(home, hooks)
    if action == "review":
        print(json.dumps(candidate, indent=2))
        print(f"Review {candidate['integrationPath']} and this exact hook in Codex /hooks. "
              f"Current Codex trust: {hook['trustStatus']}. Save this JSON as config/codex-herdr-hooks.json only after operator review.", file=sys.stderr)
        return
    review = json.loads(review_path.read_text())
    if not isinstance(review, dict) or set(review) != FIELDS or review != candidate:
        refuse("operator review is missing, malformed, or stale; run review again")
    if hook["trustStatus"] != "trusted":
        refuse("Herdr needs operator review in Codex /hooks; Firstmate never writes hook trust")
    # Codex splits CLI key paths on every dot, even inside quoted keys.
    # Put native keys in the TOML value, never in the dotted CLI path.
    states = ", ".join(
        json.dumps(item["key"]) + " = { enabled = "
        + ("true" if item["key"] == hook["key"] else "false") + " }"
        for item in hooks
    )
    flags = ["-c", "hooks.state={ " + states + " }"]
    next_home, effective = inventory(binary, cwd, flags)
    if next_home != home or len(effective) != len(hooks):
        refuse("hook source inventory changed during selection")
    before = {item["key"]: {k: v for k, v in item.items() if k != "enabled"} for item in hooks}
    after = {item["key"]: {k: v for k, v in item.items() if k != "enabled"} for item in effective}
    if before != after or any(item["enabled"] != (item["key"] == hook["key"]) for item in effective):
        refuse("Codex did not apply exclusive Herdr session selection")
    if selected(next_home, effective)[1] != candidate:
        refuse("installed integration changed during selection")
    features = subprocess.run(
        [binary, "--enable", "hooks", *flags, "features", "list"],
        cwd=cwd, check=True, capture_output=True, text=True, timeout=10,
    ).stdout.splitlines()
    hook_features = [line.split() for line in features if line.split()[:1] == ["hooks"]]
    if len(hook_features) != 1 or hook_features[0][-1] != "true":
        refuse("Codex did not enable the hook feature for this invocation")
    if action == "check":
        print(f"checked: {VERSION}; only {hook['key']} enabled; {len(hooks) - 1} unrelated hooks disabled for this session")
        return
    # Preserve notify separately from lifecycle hooks. The launch supplies its
    # existing notify override after --, alongside the existing effort value.
    os.environ.pop("CODEX_THREAD_ID", None)
    os.execv(binary, [binary, "--no-daemon", "--enable", "hooks", *flags, *launch])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"fm-codex-herdr-hooks: refused: {error}", file=sys.stderr)
        sys.exit(1)
