#!/usr/bin/env bash
# Install or remove Firstmate's guarded Antigravity (agy) crew turn-end plugin hook.
#
# This command is the sole owner of the Firstmate plugin under
# $HOME/.gemini/config/plugins/firstmate/.
# It manages plugin.json, hooks.json, and the runtime fm-turn-end.sh script.
#
# The installed hooks always exit 0, emit {} on stdout, and remain silent.
# PreInvocation applies a busy-state event. Stop checks fullyIdle; only when
# fullyIdle is true does it touch the task's turn-ended notification marker
# and apply an idle-state event.
#
# Usage:
#   fm-agy-turnend-hook.sh install
#   fm-agy-turnend-hook.sh remove
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,17{s/^# \{0,1\}//;p;}' "$0"
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
  printf 'fm-agy-turnend-hook: refused: python3 is required to manage plugin config.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-agy-turnend-hook: refused: jq is required by the installed agy turn-end hook.\n' >&2
  exit 1
fi

python3 - "$ACTION" "$HOME/.gemini/config/plugins/firstmate" <<'PY_INNER'
import json
import os
import shutil
import stat
import sys
import tempfile

ACTION = sys.argv[1]
PLUGIN_DIR = sys.argv[2]
MANIFEST = os.path.join(PLUGIN_DIR, "plugin.json")
HOOKS_CONFIG = os.path.join(PLUGIN_DIR, "hooks.json")
HOOK_SCRIPT = os.path.join(PLUGIN_DIR, "fm-turn-end.sh")
REGISTRY = os.path.join(PLUGIN_DIR, "fm-turn-end.d")

MANIFEST_CONTENT = {
    "name": "firstmate"
}

HOOKS_CONTENT = {
    "firstmate-turn-end": {
        "PreInvocation": [
            {
                "type": "command",
                "command": 'bash "$HOME/.gemini/config/plugins/firstmate/fm-turn-end.sh" pre-invocation'
            }
        ],
        "Stop": [
            {
                "type": "command",
                "command": 'bash "$HOME/.gemini/config/plugins/firstmate/fm-turn-end.sh" stop'
            }
        ]
    }
}

HOOK_SCRIPT_BYTES = b"""#!/usr/bin/env bash
# Firstmate Antigravity (agy) turn-end hook. Managed by fm-agy-turnend-hook.sh.
# This hook is deliberately passive: every path outputs valid JSON {} and exits zero.
set +e
action=${1:-stop}
payload=
IFS= read -r payload || [ -n "$payload" ]
trap 'printf "%s\\n" "{}"' EXIT
command -v jq >/dev/null 2>&1 || exit 0
workspace=$(jq -er '(.workspacePaths // [])[0] // .cwd // empty' <<< "$payload" 2>/dev/null) || exit 0
[ -n "$workspace" ] || exit 0
pointer="$workspace/.fm-agy-turnend"
[ -f "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
auth_dir=${HOME:-}/.gemini/config/plugins/firstmate/fm-turn-end.d
[ -n "${HOME:-}" ] || exit 0
auth_file="$auth_dir/$token"
[ -f "$auth_file" ] || exit 0

state_real=
id=
busy_gen=
fm_root=
turnend=
{
  IFS= read -r state_real &&
  IFS= read -r id &&
  IFS= read -r busy_gen &&
  IFS= read -r fm_root &&
  IFS= read -r turnend
} < "$auth_file" 2>/dev/null || exit 0

if [ "$action" = "pre-invocation" ]; then
  if [ -n "$fm_root" ] && [ -x "$fm_root/bin/fm-busy-event.sh" ] && [ -n "$state_real" ] && [ -n "$id" ] && [ -n "$busy_gen" ]; then
    "$fm_root/bin/fm-busy-event.sh" apply "$state_real" "$id" busy --gen "$busy_gen" --source agy-hook --event pre-invocation >/dev/null 2>&1 || true
  fi
elif [ "$action" = "stop" ]; then
  fully_idle=$(jq -r 'if .fullyIdle == null then "true" else (.fullyIdle | tostring) end' <<< "$payload" 2>/dev/null) || fully_idle=true
  if [ "$fully_idle" = "true" ]; then
    if [ -n "$turnend" ]; then
      case "$turnend" in /*.turn-ended) touch -- "$turnend" 2>/dev/null || true ;; esac
    fi
    if [ -n "$fm_root" ] && [ -x "$fm_root/bin/fm-busy-event.sh" ] && [ -n "$state_real" ] && [ -n "$id" ] && [ -n "$busy_gen" ]; then
      "$fm_root/bin/fm-busy-event.sh" apply "$state_real" "$id" idle --gen "$busy_gen" --source agy-hook --event stop >/dev/null 2>&1 || true
    fi
  fi
fi
exit 0
"""


def refuse(reason: str) -> None:
    print(f"fm-agy-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def atomic_write(path: str, data: bytes, mode: int) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


try:
    if ACTION == "install":
        os.makedirs(PLUGIN_DIR, mode=0o700, exist_ok=True)
        os.chmod(PLUGIN_DIR, 0o700)
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        atomic_write(MANIFEST, json.dumps(MANIFEST_CONTENT, indent=2).encode("utf-8") + b"\n", 0o600)
        atomic_write(HOOKS_CONFIG, json.dumps(HOOKS_CONTENT, indent=2).encode("utf-8") + b"\n", 0o600)
        atomic_write(HOOK_SCRIPT, HOOK_SCRIPT_BYTES, 0o700)
    elif ACTION == "remove":
        if os.path.lexists(PLUGIN_DIR):
            if os.path.islink(PLUGIN_DIR) or not os.path.isdir(PLUGIN_DIR):
                refuse(f"plugin directory is unexpected at {PLUGIN_DIR}")
            shutil.rmtree(PLUGIN_DIR)
except OSError as error:
    refuse(f"filesystem operation failed: {error}")
PY_INNER
