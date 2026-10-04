#!/usr/bin/env python3
"""Protocol fixture only; never invokes Herdr or touches any endpoint."""
import json
import os
from pathlib import Path
import sys

p = Path(os.environ["NATIVE_FIXTURE"])
args = sys.argv[1:]
assert args.count("--session") == 1 and args[args.index("--session") + 1] == "fixture"
cmd = args[:2]
pid = int((p / "pid").read_text())
try:
    os.kill(pid, 0)
    running = not (p / "dead").exists()
except OSError:
    running = False
if cmd == ["pane", "get"]:
    out = {"result": {"pane": {"pane_id": "w1:p1"}}}
elif cmd == ["agent", "get"]:
    out = {"result": {"agent": {"agent_status": "idle"}}} if running else {"error": {"code": "agent_not_found"}}
elif cmd == ["pane", "process-info"]:
    out = {"result": {"type": "pane_process_info", "process_info": {
        "pane_id": "w1:p1", "shell_pid": os.getppid(),
        "foreground_processes": [{"pid": pid, "name": "claude", "argv0": "claude", "argv": ["claude"]}] if running else [],
    }}}
elif cmd == ["pane", "read"]:
    print("────────\n❯ UNSENT DRAFT\n────────")
    sys.exit(0)
elif cmd == ["pane", "send-keys"]:
    with (p / "keys").open("a") as f:
        f.write(json.dumps(args) + "\n")
    out = {}
elif args[0] == "status":
    out = {"server": {"running": True, "compatible": True}}
else:
    with (p / "unexpected").open("a") as f:
        f.write(json.dumps(args) + "\n")
    sys.exit(1)
print(json.dumps(out))
