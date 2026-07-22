#!/usr/bin/env bash
# Install (or refresh) firstmate primary shell hooks into ~/.hermes/config.yaml.
#
# Hermes shell hooks are user-global. This installer surgically rewrites only the
# top-level hooks: block that points at this checkout's bin/fm-hermes-primary-hook.sh
# and leaves every other config key - including its comments, blank lines, and
# layout - byte-for-byte untouched. Only the hooks: block itself is re-serialized.
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
import re
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

def splice_hooks_block(raw, hooks):
    """Return raw config text with ONLY the top-level hooks: block rewritten,
    leaving every other line byte-stable so comments/blank lines/layout of
    unrelated keys survive. An empty hooks mapping removes the block entirely.
    Only the hooks: block itself is re-serialized (comments inside it are not
    preserved - firstmate owns those entries)."""
    new_block = (
        yaml.safe_dump({"hooks": hooks}, sort_keys=False, allow_unicode=True)
        if hooks
        else ""
    )
    lines = raw.splitlines(keepends=True)

    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^hooks[ \t]*:", ln):
            start = i
            break

    if start is None:
        if not hooks:
            return raw
        if raw and not raw.endswith("\n"):
            raw += "\n"
        return raw + new_block

    # The block runs to the next top-level construct (a column-0 key or a
    # document marker). Trailing blank lines and column-0 comments belong to
    # whatever follows, so they are excluded from the rewritten span.
    end = len(lines)
    for j in range(start + 1, len(lines)):
        ln = lines[j]
        if ln[:1] in (" ", "\t") or ln.strip() == "" or ln.lstrip().startswith("#"):
            continue
        if re.match(r"^([^\s#][^:]*:([ \t]|$)|---|\.\.\.)", ln):
            end = j
            break
    tail = end
    while tail - 1 > start:
        prev = lines[tail - 1]
        s = prev.strip()
        if s == "" or (s.startswith("#") and prev[:1] not in (" ", "\t")):
            tail -= 1
        else:
            break

    before = "".join(lines[:start])
    after = "".join(lines[tail:])
    if hooks:
        return before + new_block + after
    return before + after

raw = cfg_path.read_text() if cfg_path.exists() else ""

cfg_path.parent.mkdir(parents=True, exist_ok=True)
# Preserve a simple backup beside the live file.
if cfg_path.exists():
    bak = cfg_path.with_suffix(cfg_path.suffix + ".bak-firstmate")
    bak.write_text(raw)

cfg_path.write_text(splice_hooks_block(raw, hooks))
print(("removed" if remove else "installed") + f": {cfg_path}")
print(f"hook bridge: {hook}")
if not remove:
    print("Restart the Hermes CLI session (or relaunch with --accept-hooks) so new hooks load and consent can be granted.")
PY
