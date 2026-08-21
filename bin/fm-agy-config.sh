#!/usr/bin/env bash
# Install or remove Firstmate's global Antigravity CLI (agy) wiring.
#
# agy reads two shared, captain-owned JSON files under ~/.gemini/config, so this
# command is the sole owner of the surgical edits to both. The guarantee is a
# KEY guarantee, not a byte one: install adds or replaces exactly one
# Firstmate-owned key or entry, remove excises exactly that one, and every other
# key and value the captain wrote survives semantically intact. Their FORMATTING
# does not - the document is parsed and re-serialized as two-space JSON, so a
# hand-indented file is reflowed on the first edit. Missing directories,
# symlinked files, malformed JSON, or a non-object top level are refused without
# any write.
#
# Two things are installed, both required before an agy crewmate is usable:
#
#   hooks.json    one "firstmate-turn-end" hook set. PreInvocation records the
#                 semantic busy event, Stop records idle and touches the task's
#                 turn-end marker. Both are a guarded no-op for every agy
#                 session Firstmate did not launch: they fire only when the
#                 payload's workspacePaths holds a .fm-agy-turnend pointer whose
#                 token names a Firstmate-created entry in the private registry
#                 under ~/.gemini/config/fm-agy-turn-end.d/. That registry path
#                 is BAKED into the installed hook rather than resolved from the
#                 environment, so the hook can only ever read the registry it
#                 was installed beside.
#   skills.json   one entry declaring the user-level skills root, because agy
#                 does NOT scan ~/.claude/skills or ~/.agents/skills on its own
#                 and would otherwise never see the no-mistakes skill a crewmate
#                 has to run. The path is written ABSOLUTE: agy's documented
#                 "~/" home-relative form is accepted but not resolved in the
#                 global config (verified, agy 1.1.15), so a tilde entry loads
#                 nothing at all. A missing root is skipped rather than refused,
#                 because a scout never needs the skill and refusing would block
#                 agy entirely wherever the captain's skills live only under
#                 ~/.claude/skills. The skip is NOT silent: install names the
#                 absent root on stderr and says what it costs, so a spawn that
#                 wanted no-mistakes mode says so up front instead of failing
#                 confusingly mid-task.
#
# Usage:
#   fm-agy-config.sh install [<skills-root>]
#   fm-agy-config.sh remove [<skills-root>]
#   <skills-root> defaults to $HOME/.agents/skills; an absent root is skipped
#   with a warning on stderr and install still exits 0.
#
# FM_AGY_CONFIG_DIR overrides the config directory, defaulting to
# $HOME/.gemini/config. It is FIRSTMATE's own knob for test isolation, not a
# vendor variable: agy resolves its config root from $HOME alone and honours no
# environment override of its own (verified, agy 1.1.15), so pointing this
# anywhere but agy's real directory installs a hook agy will never load. It is
# read at INSTALL time only; the hook it writes carries the resolved path, so a
# stray export in one process cannot split the two ends of the guard apart.
#   Both verbs take it, and remove drops only an entry it could have written -
#   exactly {"path": <skills-root>} - so an entry the captain wrote for the same
#   root with their own include_only/exclude filters is left alone.
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove [<skills-root>]\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-agy-config: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-agy-config: refused: python3 is required to edit the shared agy config safely.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-agy-config: refused: jq is required by the installed agy turn-end hook.\n' >&2
  exit 1
fi

AGY_CONFIG_DIR="${FM_AGY_CONFIG_DIR:-$HOME/.gemini/config}"
SKILLS_ROOT=${2:-$HOME/.agents/skills}

python3 - "$ACTION" "$AGY_CONFIG_DIR" "$SKILLS_ROOT" <<'PY'
import json
import os
import shlex
import shutil
import stat
import sys
import tempfile

ACTION, CONFIG_DIR, SKILLS_ROOT = sys.argv[1], sys.argv[2], sys.argv[3]
HOOKS = os.path.join(CONFIG_DIR, "hooks.json")
SKILLS = os.path.join(CONFIG_DIR, "skills.json")
HOOK = os.path.join(CONFIG_DIR, "fm-agy-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "fm-agy-turn-end.d")
HOOK_KEY = "firstmate-turn-end"

# The hook is deliberately passive: every path is silent and exits zero, so a
# Firstmate bug can never break the captain's own agy session. It reads the
# event name from argv because agy's payload does not name the event, and the
# workspace from payload.workspacePaths, which fm-spawn populates by passing
# --add-dir <worktree> (an agy launch without it reports an EMPTY array, so the
# guard would simply never fire rather than fire wrongly).
HOOK_TEMPLATE = b'''#!/usr/bin/env bash
# Firstmate agy turn-end and busy-state hook. Managed by fm-agy-config.sh.
# Silent on every path, always exits zero.
#
# The registry directory below is BAKED IN at install time, never resolved from
# the environment. The entry is minted by bin/fm-spawn.sh in firstmate's own
# environment while this hook runs in whatever agy inherited from its pane, which
# comes from the long-lived multiplexer daemon; reading FM_AGY_CONFIG_DIR at both
# ends would let those two disagree, and since every path here is silent the
# result would be a task whose signals never fire with nothing to say why.
#
# Registry entry format (written only by bin/fm-spawn.sh, mode 0700 directory,
# one file per live Firstmate agy task), five lines:
#   1 absolute path to state/<id>.turn-ended
#   2 absolute path to bin/fm-busy-event.sh in that task's own firstmate code root
#   3 absolute path to that home's state/ directory
#   4 task id
#   5 busy generation token
set +e
event=${1:-}
case "$event" in busy|idle) : ;; *) exit 0 ;; esac
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
auth_dir=@@AUTH_DIR@@
[ -d "$auth_dir" ] || exit 0
# agy reports a turn finished only when it is fully idle; a Stop carrying
# fullyIdle=false is a mid-turn boundary and must publish neither idle nor a
# turn-end wake.
if [ "$event" = idle ]; then
  jq -e '.fullyIdle == true' <<< "$payload" >/dev/null 2>&1 || exit 0
fi
while IFS= read -r workspace; do
  case "$workspace" in /*) : ;; *) continue ;; esac
  pointer="$workspace/.fm-agy-turnend"
  [ -f "$pointer" ] || continue
  first=
  IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || continue
  case "$first" in token=*) token=${first#token=} ;; *) continue ;; esac
  case "$token" in fm.????????????) : ;; *) continue ;; esac
  case "$token" in *[!A-Za-z0-9._-]*) continue ;; esac
  entry="$auth_dir/$token"
  [ -f "$entry" ] || continue
  turnend=$(sed -n 1p "$entry" 2>/dev/null) || continue
  case "$turnend" in /*.turn-ended) : ;; *) continue ;; esac
  [ "$event" != idle ] || touch -- "$turnend" 2>/dev/null
  applier=$(sed -n 2p "$entry" 2>/dev/null)
  state=$(sed -n 3p "$entry" 2>/dev/null)
  id=$(sed -n 4p "$entry" 2>/dev/null)
  gen=$(sed -n 5p "$entry" 2>/dev/null)
  case "$applier" in /*) : ;; *) continue ;; esac
  [ -x "$applier" ] || continue
  [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ] || continue
  "$applier" apply "$state" "$id" "$event" --gen "$gen" --source agy-hook \
    --event "agy-$event" 2>/dev/null
done <<< "$(jq -r '.workspacePaths[]? | strings' <<< "$payload" 2>/dev/null)"
exit 0
'''

HOOK_BYTES = HOOK_TEMPLATE.replace(b"@@AUTH_DIR@@", shlex.quote(REGISTRY).encode("utf-8"))


def refuse(reason):
    print(f"fm-agy-config: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def read_json_object(path, label):
    """Return (raw_bytes, parsed_dict) for an existing config, or (None, {})."""
    if not os.path.lexists(path):
        return None, {}
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    with open(path, "rb") as stream:
        raw = stream.read()
    if not raw.strip():
        return raw, {}
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        refuse(f"{label} is not valid JSON at {path}: {error}.")
    if not isinstance(parsed, dict):
        refuse(f"{label} has a non-object top-level value at {path}.")
    return raw, parsed


def atomic_write(path, data, mode):
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


def write_object(path, raw, parsed, label):
    candidate = (json.dumps(parsed, indent=2) + "\n").encode("utf-8")
    if raw is not None and raw == candidate:
        return
    mode = 0o600
    if raw is not None:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    atomic_write(path, candidate, mode)


def hook_block():
    def entry(event):
        return {
            "type": "command",
            "command": f"bash {shlex.quote(HOOK)} {event}",
            "timeout": 10,
        }

    return {
        "PreInvocation": [entry("busy")],
        "Stop": [entry("idle")],
    }


try:
    if not os.path.isdir(CONFIG_DIR) or os.path.islink(CONFIG_DIR):
        refuse(f"agy config directory is missing or unexpected at {CONFIG_DIR}.")
    hooks_raw, hooks = read_json_object(HOOKS, "agy hooks.json")
    skills_raw, skills = read_json_object(SKILLS, "agy skills.json")

    if ACTION == "install":
        if os.path.lexists(REGISTRY):
            info = os.lstat(REGISTRY)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
        if os.path.lexists(HOOK):
            info = os.lstat(HOOK)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                refuse(f"Firstmate hook script is not a regular non-symlink file at {HOOK}.")
            with open(HOOK, "rb") as stream:
                existing = stream.read()
            if existing != HOOK_BYTES and not existing.startswith(
                b"#!/usr/bin/env bash\n# Firstmate agy turn-end"
            ):
                refuse(f"Firstmate hook path has unexpected content at {HOOK}.")
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        if not os.path.exists(HOOK) or open(HOOK, "rb").read() != HOOK_BYTES \
                or stat.S_IMODE(os.stat(HOOK).st_mode) != 0o700:
            atomic_write(HOOK, HOOK_BYTES, 0o700)

        hooks[HOOK_KEY] = hook_block()
        write_object(HOOKS, hooks_raw, hooks, "agy hooks.json")

        # The skills entry is additive and idempotent: an entry the captain
        # already wrote for the same root is left exactly as it is, including
        # any include_only/exclude filters they chose.
        if not os.path.isdir(SKILLS_ROOT):
            print(
                "fm-agy-config: warning: skipped the agy skills declaration: no "
                f"skills root at {SKILLS_ROOT}. An agy crewmate started now cannot "
                "see the no-mistakes skill.",
                file=sys.stderr,
            )
        else:
            entries = skills.get("entries")
            if entries is None:
                entries = []
            if not isinstance(entries, list):
                refuse(f"agy skills.json has a non-array 'entries' value at {SKILLS}.")
            if not any(
                isinstance(item, dict) and item.get("path") == SKILLS_ROOT for item in entries
            ):
                entries = entries + [{"path": SKILLS_ROOT}]
            skills["entries"] = entries
            write_object(SKILLS, skills_raw, skills, "agy skills.json")
    else:
        if HOOK_KEY in hooks:
            del hooks[HOOK_KEY]
            if hooks or hooks_raw is not None:
                write_object(HOOKS, hooks_raw, hooks, "agy hooks.json")
        entries = skills.get("entries")
        if isinstance(entries, list):
            kept = [
                item
                for item in entries
                if not (
                    isinstance(item, dict)
                    and item.get("path") == SKILLS_ROOT
                    and set(item) == {"path"}
                )
            ]
            if len(kept) != len(entries):
                skills["entries"] = kept
                write_object(SKILLS, skills_raw, skills, "agy skills.json")
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            info = os.lstat(REGISTRY)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
            shutil.rmtree(REGISTRY)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY
