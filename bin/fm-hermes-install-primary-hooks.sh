#!/usr/bin/env bash
# Install (or refresh) firstmate primary shell hooks into ~/.hermes/config.yaml.
#
# Hermes shell hooks are user-global. This installer merges a firstmate-owned
# hooks: block that points at this checkout's bin/fm-hermes-primary-hook.sh and
# leaves every other config key untouched.
#
# Usage:
#   bin/fm-hermes-install-primary-hooks.sh           # install/refresh
#   bin/fm-hermes-install-primary-hooks.sh --status  # print whether installed
#   bin/fm-hermes-install-primary-hooks.sh --remove  # remove firstmate entries only
#
# Requires: python3 + PyYAML (Hermes already depends on PyYAML).
# Consent: Hermes prompts on first use of each (event, command) unless
# --accept-hooks / HERMES_ACCEPT_HOOKS / hooks_auto_accept is set. The captain
# should accept once, or relaunch with --accept-hooks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$FM_ROOT/bin/fm-hermes-primary-hook.sh"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CFG="${FM_HERMES_CONFIG:-$HERMES_HOME/config.yaml}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
}

STATUS=0
REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS=1 ;;
    --remove) REMOVE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -x "$HOOK" ]; then
  echo "error: missing executable hook bridge: $HOOK" >&2
  exit 1
fi

python3 - "$CFG" "$HOOK" "$STATUS" "$REMOVE" <<'PY'
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1]).expanduser()
hook = str(Path(sys.argv[2]).expanduser())
status_only = sys.argv[3] == "1"
remove = sys.argv[4] == "1"

try:
    import yaml
except ImportError:
    sys.stderr.write("error: PyYAML is required (Hermes ships it)\n")
    sys.exit(1)

MARKER = "firstmate-primary"

def is_fm_entry(entry) -> bool:
    if not isinstance(entry, dict):
        return False
    cmd = str(entry.get("command") or "")
    return MARKER in cmd or cmd.endswith("fm-hermes-primary-hook.sh") or "fm-hermes-primary-hook.sh" in cmd

def load():
    if not cfg_path.exists():
        return {}
    data = yaml.safe_load(cfg_path.read_text()) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"error: {cfg_path} is not a mapping")
    return data

data = load()
hooks = data.get("hooks")
if hooks is None:
    hooks = {}
if not isinstance(hooks, dict):
    raise SystemExit("error: hooks: must be a mapping")

desired = {
    "pre_tool_call": [{
        "command": f"{hook} pre_tool_call",
        "timeout": 15,
        "matcher": "terminal",
    }],
    "pre_llm_call": [{
        "command": f"{hook} pre_llm_call",
        "timeout": 10,
    }],
    "post_llm_call": [{
        "command": f"{hook} post_llm_call",
        "timeout": 20,
    }],
}

def present() -> bool:
    for event, want in desired.items():
        entries = hooks.get(event) or []
        if not isinstance(entries, list):
            return False
        if not any(is_fm_entry(e) for e in entries):
            return False
    return True

if status_only:
    print("installed" if present() else "missing")
    sys.exit(0 if present() else 1)

# Drop prior firstmate entries (refresh or remove).
for event in list(hooks.keys()):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    kept = [e for e in entries if not is_fm_entry(e)]
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)

if not remove:
    for event, entries in desired.items():
        cur = hooks.get(event) or []
        if not isinstance(cur, list):
            cur = []
        hooks[event] = cur + entries

if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)

cfg_path.parent.mkdir(parents=True, exist_ok=True)
# Preserve a simple backup beside the live file.
if cfg_path.exists():
    bak = cfg_path.with_suffix(cfg_path.suffix + ".bak-firstmate")
    bak.write_text(cfg_path.read_text())

cfg_path.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
print(("removed" if remove else "installed") + f": {cfg_path}")
print(f"hook bridge: {hook}")
if not remove:
    print("Restart the Hermes CLI session (or relaunch with --accept-hooks) so new hooks load and consent can be granted.")
PY
