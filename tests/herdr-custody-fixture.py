import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
endpoint = Path(os.environ["FM_FAKE_ENDPOINT_FILE"])
label_path = Path(os.environ["FM_FAKE_TMUX_LABEL_FILE"])
label = label_path.read_text().strip() if label_path.exists() else "unused"
live = endpoint.exists()
workspace = {"workspace_id": "ws-custody", "label": "firstmate"}
tab = {"tab_id": "tab-custody", "workspace_id": "ws-custody", "label": label}
pane = {"pane_id": "pane-custody", "tab_id": "tab-custody", "workspace_id": "ws-custody", "foreground_cwd": os.environ.get("FM_FAKE_PANE_PATH", "")}
command = tuple(args[:2])
if command == ("status", "--json"):
    print(json.dumps({"client": {"version": "0.7.3", "protocol": 14}, "server": {"running": True}}))
    sys.exit(0)
elif command == ("session", "list"):
    print(json.dumps({"sessions": [{"name": "default", "running": True}]}))
    sys.exit(0)
elif command == ("workspace", "list"):
    result = {"workspaces": [workspace]}
elif command == ("tab", "list"):
    result = {"tabs": [tab] if live else []}
elif command == ("pane", "list"):
    result = {"panes": [pane] if live else []}
elif command == ("tab", "create"):
    label_path.write_text(args[args.index("--label") + 1])
    result = {"tab": tab, "root_pane": {"pane_id": "shell-custody"}}
elif command == ("agent", "start"):
    endpoint.touch()
    argv = args[args.index("--") + 1:]
    Path(os.environ["FM_FAKE_LAUNCH_LOG"]).write_text(argv[-1])
    result = {"agent": {"pane_id": "pane-custody", "tab_id": "tab-custody"}}
elif command == ("pane", "get"):
    if not live:
        print(json.dumps({"error": {"code": "pane_not_found"}}))
        sys.exit(1)
    result = {"pane": pane}
elif command == ("agent", "get"):
    result = {"agent": {"agent_status": "working"}}
elif command == ("pane", "close") and args[2] == "shell-custody":
    result = {}
elif command in (("pane", "close"), ("tab", "close")):
    endpoint.unlink(missing_ok=True)
    result = {}
else:
    print(f"unsupported fixture command: {args}", file=sys.stderr)
    sys.exit(2)
print(json.dumps({"result": result}))
