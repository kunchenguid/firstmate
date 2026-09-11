#!/usr/bin/env python3
"""Small, serialized fake CLI for spawn/teardown presentation composition tests."""
import fcntl
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["FM_PRESENTATION_FIXTURE"])
args = sys.argv[1:]
if args not in (["status", "--json"], ["--version"]):
    assert args[-2:] == ["--session", "fmtest"], args
    args = args[:-2]
cmd = args[:2]


def option(name, default=""):
    return args[args.index(name) + 1] if name in args else default


def respond(value):
    print(json.dumps(value))


# Pause outside the fake server's own state lock, just as a slow launch RPC
# must not prevent unrelated session operations from reaching the server.
if cmd == ["pane", "run"] and 'sh -c "launch-probe"' in args[3]:
    pane = args[2]
    (root / (pane + ".starting")).touch()
    # Two real spawn pipelines and a teardown must fit even on loaded CI.
    deadline = time.monotonic() + 600
    while not (root / "continue").exists():
        if time.monotonic() > deadline:
            sys.exit(1)
        time.sleep(0.1)

with (root / "server.lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    path = root / "server.json"
    state = json.loads(path.read_text())
    spaces, tabs, panes = state["workspaces"], state["tabs"], state["panes"]
    result = {}
    if cmd == ["status", "--json"]:
        respond({"client": {"version": "0.8.0", "protocol": 16}, "server": {"running": True}})
        sys.exit(0)
    if cmd == ["session", "list"]:
        respond({"sessions": [{"name": "fmtest", "running": True, "socket_path": str(root / "herdr.sock")}]})
        sys.exit(0)
    if args == ["--version"]:
        print("herdr 0.8.0")
        sys.exit(0)
    if cmd[0] in ("workspace", "tab", "pane"):
        kind, action = cmd
        rows = {"workspace": spaces, "tab": tabs, "pane": panes}[kind]
        key = kind + "_id"
        if action == "list":
            result[kind + "s"] = [r for r in rows if not option("--workspace") or r["workspace_id"] == option("--workspace")]
        elif action == "get":
            matches = [r for r in rows if r[key] == args[2]]
            if not matches:
                respond({"error": {"code": kind + "_not_found"}})
                sys.exit(1)
            result[kind] = matches[0]
        elif action == "create":
            state["next"] += 1
            n = str(state["next"])
            ws = "w" + n if kind == "workspace" else option("--workspace")
            tab = {"workspace_id": ws, "tab_id": ws + ":t" + n, "label": "1" if kind == "workspace" else option("--label"), "focused": True}
            pane = {"workspace_id": ws, "tab_id": tab["tab_id"], "pane_id": ws + ":p" + n, "foreground_cwd": os.environ["FM_FAKE_PANE_PATH"]}
            tabs.append(tab)
            panes.append(pane)
            if kind == "workspace":
                spaces.append({"workspace_id": ws, "label": option("--label"), "active_tab_id": tab["tab_id"], "focused": False})
                result["workspace"] = spaces[-1]
            else:
                for s in spaces:
                    if s["workspace_id"] == ws:
                        s["active_tab_id"] = tab["tab_id"]
                for t in tabs:
                    if t["workspace_id"] == ws:
                        t["focused"] = t is tab
            result.update(tab=tab, root_pane=pane)
        elif action == "close" and kind == "pane":
            target = next(p for p in panes if p["pane_id"] == args[2])
            panes.remove(target)
            tabs[:] = [t for t in tabs if t["tab_id"] != target["tab_id"]]
            spaces[:] = [s for s in spaces if any(t["workspace_id"] == s["workspace_id"] for t in tabs)]
        elif action == "report-metadata":
            # Keep the parent token used by the real ordering planner.
            for r in rows:
                if r[key] == args[2] and option("--token"):
                    name, value = option("--token").split("=", 1)
                    r.setdefault("tokens", {})[name] = value
        elif action not in ("run", "send-keys", "send-text", "capture"):
            raise AssertionError(args)
    elif cmd == ["agent", "get"]:
        respond({"error": {"code": "agent_not_found"}})
        sys.exit(1)
    else:
        raise AssertionError(args)
    path.write_text(json.dumps(state))
    respond({"result": result})
