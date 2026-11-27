#!/usr/bin/env python3
"""Stateful Herdr CLI boundary for fm-spawn-herdr-lease.test.sh.

Models workspace/tab/pane identity and no-focus mutations, not spawn decisions.
No server, socket, harness, or pool is started.
"""
import fcntl
import json
import os
from pathlib import Path
import shlex
import sys

root = Path(os.environ["FM_FAKE_DIR"])
args = sys.argv[1:]
if "--session" in args:
    i = args.index("--session")
    del args[i:i + 2]


def option(name, default=None):
    return args[args.index(name) + 1] if name in args else default


def tab(workspace, ident, label, cwd, focused=False):
    return {"tab_id": ident, "workspace_id": workspace, "label": label,
            "focused": focused, "cwd": cwd}


def pane(workspace, ident, tab_id, cwd):
    return {"pane_id": ident, "workspace_id": workspace, "tab_id": tab_id,
            "cwd": cwd, "foreground_cwd": cwd}


with (root / "model.lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    statefile = root / "model.json"
    if statefile.exists():
        state = json.loads(statefile.read_text())
    else:
        state = {"workspaces": [{"workspace_id": "parent", "label": "firstmate",
                                  "focused": True, "active_tab_id": "parent:t1"}],
                 "tabs": [tab("parent", "parent:t1", "primary", "/", True)],
                 "panes": [pane("parent", "parent:p1", "parent:t1", "/")],
                 "agents": [], "next": 1}
    workspaces, tabs, panes = (state[k] for k in ("workspaces", "tabs", "panes"))
    with (root / "herdr-log").open("a") as log:
        log.write(" ".join(args) + "\n")
    result = {}
    error = None
    command = tuple(args[:2])
    if args[0] == "seed":
        ident, home, cwd, token = args[1:]
        ws, tid, pid = "husk-" + ident, "old-tab-" + ident, "old-pane-" + ident
        label = "└ " + ident + " · p:" + token
        workspaces.append({"workspace_id": ws, "label": label, "focused": False,
                           "active_tab_id": tid})
        tabs.append(tab(ws, tid, "fm-" + ident, cwd))
        panes.append(pane(ws, pid, tid, cwd))
        fields = dict(version=2, task_id=ident, projection_id=token, home=home,
                      session="default", workspace_id=ws, tab_id=tid, pane_id=pid,
                      parent_workspace_id="parent", parent_label="firstmate",
                      workspace_label=label, task_label="fm-" + ident)
        target = Path(home) / "state"
        (target / (ident + ".herdr-presentation")).write_text(
            "".join(f"{key}={value}\n" for key, value in fields.items()))
        (target / (ident + ".meta")).write_text(
            f"backend=herdr\nwindow=default:{pid}\nherdr_session=default\n"
            f"herdr_workspace_id={ws}\nherdr_tab_id={tid}\nherdr_pane_id={pid}\n")
    elif args[0] == "status":
        print(json.dumps({"client": {"version": "0.9.0", "protocol": 22},
                          "server": {"running": True}}))
        sys.exit(0)
    elif command == ("session", "list"):
        print(json.dumps({"sessions": [{"name": "default", "running": True,
                                        "socket_path": str(root / "herdr.sock") }]}))
        sys.exit(0)
    elif command == ("workspace", "list"):
        result = {"workspaces": workspaces}
    elif command == ("workspace", "create"):
        ws = "new-ws-" + str(state["next"])
        state["next"] += 1
        tid, pid = ws + ":seed-tab", ws + ":seed-pane"
        workspaces.append({"workspace_id": ws, "label": option("--label"),
                           "focused": False, "active_tab_id": tid})
        tabs.append(tab(ws, tid, "1", option("--cwd")))
        panes.append(pane(ws, pid, tid, option("--cwd")))
        result = {"workspace": workspaces[-1], "tab": tabs[-1], "root_pane": panes[-1]}
    elif command == ("tab", "create"):
        ws = option("--workspace")
        tid, pid = ws + ":t" + str(state["next"]), ws + ":p" + str(state["next"])
        state["next"] += 1
        tabs.append(tab(ws, tid, option("--label"), option("--cwd")))
        panes.append(pane(ws, pid, tid, option("--cwd")))
        result = {"tab": tabs[-1], "root_pane": panes[-1]}
    elif command in (("tab", "list"), ("pane", "list")):
        key = "tabs" if args[0] == "tab" else "panes"
        result = {key: [item for item in state[key]
                        if item["workspace_id"] == option("--workspace")]}
    elif command in (("tab", "get"), ("pane", "get")):
        kind = args[0]
        found = [item for item in state[kind + "s"] if item[kind + "_id"] == args[2]]
        if found:
            result = {kind: found[0]}
        else:
            error = {"code": kind + "_not_found"}
    elif command in (("tab", "close"), ("pane", "close")):
        tid = args[2] if args[0] == "tab" else next(
            item["tab_id"] for item in panes if item["pane_id"] == args[2])
        tabs[:] = [item for item in tabs if item["tab_id"] != tid]
        panes[:] = [item for item in panes if item["tab_id"] != tid]
    elif command == ("agent", "get"):
        if args[2] in state["agents"]:
            result = {"agent": {"agent_status": "idle"}}
        else:
            error = {"code": "agent_not_found"}
    elif command in (("pane", "run"), ("pane", "send-text")):
        payload = args[3]
        if payload.startswith(". '"):
            payload = Path(shlex.split(payload)[1]).read_text()
        current = next(item for item in panes if item["pane_id"] == args[2])
        if payload.startswith("cd -- "):
            current["cwd"] = current["foreground_cwd"] = shlex.split(payload)[2]
        elif "encode launch-brief" in payload or "Firstmate operational input waiting: read" in payload:
            state["agents"].append(args[2])
    elif command == ("pane", "send-keys") or args[0] == "server" or command[:1] == ("terminal",):
        pass
    else:
        raise SystemExit("unsupported fake Herdr command: " + repr(args))
    statefile.write_text(json.dumps(state, ensure_ascii=False))
    print(json.dumps({"error": error} if error else {"result": result}, ensure_ascii=False))
