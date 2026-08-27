#!/usr/bin/env bash
# Install or remove Firstmate's guarded agy (Antigravity CLI) crew turn-end hook.
#
# This command is the sole owner of the named Firstmate key in
# $HOME/.gemini/config/hooks.json. install creates that file when absent, or
# upserts only the fm-agy-turn-end key when the file already holds other hooks.
# remove deletes only that key. Missing, malformed, symlinked, or otherwise
# surprising JSON is refused without a config write, as is an install over a
# hook script path or token registry that does not hold the Firstmate-owned
# shape. remove always de-registers the key first, then refuses to delete a
# hook script or registry it no longer recognizes.
#
# The installed Stop hook always exits 0 and stays silent. It reads
# workspacePaths from the hook payload, checks for a .fm-agy-turnend pointer
# before registry work, and touches a task turn-end marker only when the
# pointer names a Firstmate-created token in $HOME/.gemini/config/fm-agy-turn-end.d/.
#
# Usage:
#   fm-agy-turnend-hook.sh install
#   fm-agy-turnend-hook.sh remove
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,20{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-agy-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-agy-turnend-hook: refused: python3 is required to edit hooks.json.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-agy-turnend-hook: refused: jq is required by the installed agy turn-end hook.\n' >&2
  exit 1
fi

CONFIG_DIR="${HOME}/.gemini/config"
HOOK_KEY=fm-agy-turn-end

python3 - "$ACTION" "$CONFIG_DIR" "$HOOK_KEY" <<'PY'
import json
import os
import stat
import sys
import tempfile

ACTION = sys.argv[1]
CONFIG_DIR = sys.argv[2]
HOOK_KEY = sys.argv[3]
CONFIG = os.path.join(CONFIG_DIR, "hooks.json")
HOOK = os.path.join(CONFIG_DIR, "fm-agy-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "fm-agy-turn-end.d")

HOOK_PREFIX = b"#!/usr/bin/env bash\n# Firstmate agy turn-end hook."

HOOK_BYTES = b'''#!/usr/bin/env bash
# Firstmate agy turn-end hook. Managed by fm-agy-turnend-hook.sh.
# This hook is deliberately passive: every path is silent and exits zero.
set +e
exec >/dev/null 2>&1
# The whole payload, not its first line: agy is free to pretty-print the Stop
# JSON, and a lone `{` would silently stop every turn-end wake.
payload=$(cat)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
auth_dir=${HOME:-}/.gemini/config/fm-agy-turn-end.d
[ -n "${HOME:-}" ] || exit 0
# workspacePaths is an ARRAY: a multi-root Stop payload may list this task's
# worktree at any index, and reading only [0] loses the wake silently. Every
# candidate still has to pass the same pointer, token and registry gate.
while IFS= read -r workspace; do
  pointer="$workspace/.fm-agy-turnend"
  [ -f "$pointer" ] || continue
  first=
  IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || continue
  case "$first" in token=*) token=${first#token=} ;; *) continue ;; esac
  case "$token" in fm.????????????) : ;; *) continue ;; esac
  case "$token" in *[!A-Za-z0-9._-]*) continue ;; esac
  target=$(cat "$auth_dir/$token" 2>/dev/null) || continue
  case "$target" in /*.turn-ended) : ;; *) continue ;; esac
  touch -- "$target" 2>/dev/null || true
done < <(jq -r '.workspacePaths[]? | strings | select(length > 0)' <<< "$payload" 2>/dev/null)
exit 0
'''


def refuse(reason: str) -> None:
    print(f"fm-agy-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path: str, label: str):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def private_dir(path: str, label: str, enforce_mode: bool) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        os.makedirs(path, mode=0o700, exist_ok=True)
        return
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        refuse(f"{label} is not a regular non-symlink directory at {path}.")
    if enforce_mode:
        os.chmod(path, 0o700)


def check_hook_path() -> None:
    if not os.path.lexists(HOOK):
        return
    regular_not_symlink(HOOK, "Firstmate hook script")
    with open(HOOK, "rb") as stream:
        existing = stream.read()
    if existing != HOOK_BYTES and not existing.startswith(HOOK_PREFIX):
        refuse(f"Firstmate hook path has unexpected content at {HOOK}.")


def check_registry_path() -> None:
    if not os.path.lexists(REGISTRY):
        return
    info = os.lstat(REGISTRY)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        refuse(f"Firstmate registry is not a regular non-symlink directory at {REGISTRY}.")


def load_hooks(path: str):
    info = regular_not_symlink(path, "hooks.json")
    if info is None:
        return {}
    try:
        text = open(path, "r", encoding="utf-8").read()
    except OSError as error:
        refuse(f"hooks.json could not be read at {path}: {error}.")
    if not text.strip():
        return {}
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as error:
        refuse(f"hooks.json is malformed JSON at {path}: {error}.")
    if not isinstance(parsed, dict):
        refuse(f"hooks.json must be a JSON object at {path}.")
    return parsed


def atomic_write(path: str, data: dict) -> None:
    directory = os.path.dirname(path)
    private_dir(directory, "agy config directory", False)
    fd, tmp = tempfile.mkstemp(prefix=".fm-agy-hooks.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_hook_script() -> None:
    check_hook_path()
    check_registry_path()
    private_dir(CONFIG_DIR, "agy config directory", False)
    private_dir(REGISTRY, "Firstmate registry", True)
    fd, tmp = tempfile.mkstemp(prefix=".fm-agy-hook.", dir=CONFIG_DIR)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(HOOK_BYTES)
        os.chmod(tmp, 0o700)
        os.replace(tmp, HOOK)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


entry = {
    "Stop": [
        {
            "type": "command",
            "command": HOOK,
            "timeout": 10,
        }
    ]
}

if ACTION == "install":
    hooks = load_hooks(CONFIG)
    hooks[HOOK_KEY] = entry
    # The script first: hooks.json must never name a command that does not exist.
    write_hook_script()
    atomic_write(CONFIG, hooks)
    raise SystemExit(0)

hooks = load_hooks(CONFIG)
# De-register first: agy must stop running the command whatever state the file
# it names is in. Only the deletion of Firstmate's own files is guarded.
if HOOK_KEY in hooks:
    del hooks[HOOK_KEY]
    if hooks:
        atomic_write(CONFIG, hooks)
    elif os.path.exists(CONFIG):
        os.unlink(CONFIG)
check_hook_path()
check_registry_path()
if os.path.lexists(HOOK):
    os.unlink(HOOK)
if os.path.isdir(REGISTRY):
    try:
        os.rmdir(REGISTRY)
    except OSError:
        pass
raise SystemExit(0)
PY
