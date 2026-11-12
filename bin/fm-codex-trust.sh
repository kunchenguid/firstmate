#!/usr/bin/env bash
# Register the exact Firstmate-owned directory a Codex worker starts in as trusted.
# The registration is limited to a linked task worktree or a validated secondmate home.
set -u

usage() {
  printf '%s\n' \
    'usage: fm-codex-trust.sh <worktree> <project>' \
    '       fm-codex-trust.sh --secondmate-home <home> <id>' >&2
  exit 2
}

refuse() {
  echo "error: refusing to pre-register Codex trust: $1" >&2
  exit 1
}

real_dir() {
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

case "${1:-}" in
  --secondmate-home)
    [ "$#" -eq 3 ] || usage
    MODE=secondmate
    TARGET_ARG=$2
    SUB_ID=$3
    PROJECT_ARG=
    ;;
  '' | -h | --help)
    usage
    ;;
  *)
    [ "$#" -eq 2 ] || usage
    MODE=worktree
    TARGET_ARG=$1
    PROJECT_ARG=$2
    SUB_ID=
    ;;
esac

TARGET_REAL=$(real_dir "$TARGET_ARG") || true
[ -n "$TARGET_REAL" ] || refuse "target '$TARGET_ARG' is not an accessible directory"

if [ "$MODE" = worktree ]; then
  PROJECT_REAL=$(real_dir "$PROJECT_ARG") || true
  [ -n "$PROJECT_REAL" ] || refuse "project '$PROJECT_ARG' is not an accessible directory"
  TARGET_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$TARGET_TOP" ] && [ "$(real_dir "$TARGET_TOP")" = "$TARGET_REAL" ] \
    || refuse "target '$TARGET_REAL' is not the top level of a git worktree"
  TARGET_GIT=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  TARGET_COMMON=$(git -C "$TARGET_REAL" rev-parse --git-common-dir 2>/dev/null) || true
  PROJECT_COMMON=$(git -C "$PROJECT_REAL" rev-parse --git-common-dir 2>/dev/null) || true
  TARGET_GIT=$(real_dir "$TARGET_GIT") || true
  TARGET_COMMON=$(cd -P "$TARGET_REAL" && real_dir "$TARGET_COMMON") || true
  PROJECT_COMMON=$(cd -P "$PROJECT_REAL" && real_dir "$PROJECT_COMMON") || true
  [ -n "$TARGET_GIT" ] && [ -n "$TARGET_COMMON" ] && [ -n "$PROJECT_COMMON" ] \
    || refuse "could not resolve the git worktree boundary"
  [ "$TARGET_GIT" != "$TARGET_COMMON" ] || refuse "target '$TARGET_REAL' is a primary checkout, not an isolated worktree"
  [ "$TARGET_COMMON" = "$PROJECT_COMMON" ] \
    || refuse "target '$TARGET_REAL' is not a worktree of project '$PROJECT_REAL'"
else
  marker="$TARGET_REAL/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] \
    || refuse "target '$TARGET_REAL' is not an owned seeded secondmate home"
  [ "$(cat "$marker" 2>/dev/null)" = "$SUB_ID" ] \
    || refuse "target '$TARGET_REAL' is marked for another secondmate"
  [ -f "$TARGET_REAL/AGENTS.md" ] && [ -d "$TARGET_REAL/bin" ] \
    || refuse "target '$TARGET_REAL' is not a complete seeded secondmate home"
fi

PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON=$(command -v "$candidate")
    break
  fi
done
[ -n "$PYTHON" ] || refuse "Python 3.11+ with tomllib is required to validate Codex config.toml"

if [ -n "${CODEX_HOME:-}" ]; then
  CONFIG_ROOT=$CODEX_HOME
elif [ -n "${HOME:-}" ]; then
  case "$HOME" in
    /*) CONFIG_ROOT=$HOME/.codex ;;
    *) refuse "HOME must be an absolute path" ;;
  esac
else
  refuse "neither CODEX_HOME nor HOME is set"
fi
case "$CONFIG_ROOT" in
  /*) ;;
  *) refuse "CODEX_HOME must be an absolute path" ;;
esac
mkdir -p "$CONFIG_ROOT" || refuse "could not create Codex config directory '$CONFIG_ROOT'"
CONFIG_ROOT=$(real_dir "$CONFIG_ROOT") || refuse "Codex config directory '$CONFIG_ROOT' could not be resolved"
STORE="$CONFIG_ROOT/config.toml"
if [ -L "$STORE" ]; then
  STORE=$("$PYTHON" - "$STORE" <<'PY'
import os, sys
try:
    print(os.path.realpath(sys.argv[1]))
except OSError:
    raise SystemExit(1)
PY
) || refuse "Codex config symlink '$CONFIG_ROOT/config.toml' could not be resolved"
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "Codex config '$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "Codex config '$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "Codex config '$STORE' is not writable"
fi

if ! "$PYTHON" - "$STORE" "$TARGET_REAL" <<'PY'
import fcntl
import hashlib
import os
import pathlib
import re
import shutil
import stat
import sys
import tempfile
import tomllib

store = pathlib.Path(sys.argv[1])
target = sys.argv[2]
# Serialize every registration into this store across the whole read, edit,
# and replace, so concurrent spawns never drop each other's entries.
store.parent.mkdir(parents=True, exist_ok=True)
lock_fd = os.open(store.parent / f".{store.name}.fm-codex-trust.lock", os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(lock_fd, fcntl.LOCK_EX)
original = store.read_bytes() if store.exists() else b""
try:
    parsed = tomllib.loads(original.decode())
except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
    raise SystemExit(f"Codex config '{store}' is invalid TOML: {exc}")

projects = parsed.get("projects", {})
entry = projects.get(target, {}) if isinstance(projects, dict) else {}
if isinstance(entry, dict) and entry.get("trust_level") == "trusted":
    print(f"trusted: {target} (already registered)")
    raise SystemExit(0)

text = original.decode() if original else ""
escaped = target.replace("\\", "\\\\").replace('"', '\\"')
header = f'[projects."{escaped}"]'
header_re = re.compile(r'^[ \t]*(?P<header>\[[ \t]*projects[ \t]*\.[ \t]*(?:"(?:[^"\\]|\\.)*"|\'[^\']*\')[ \t]*\])[ \t]*(?:#.*)?(?:\r?\n)?$')
table_re = re.compile(r'^[ \t]*\[\[?[^\n]+\]\]?[ \t]*(?:#.*)?(?:\r?\n)?$')

# TOML strings can contain anything that resembles a table or assignment,
# including newlines.  Find structural lines only while outside strings.
def next_string_state(line, state):
    index = 0
    while index < len(line):
        if state:
            if state == '"""' and line[index] == '\\':
                index += 2
            elif line.startswith(state, index):
                index += 3
                state = None
            else:
                index += 1
            continue
        if line.startswith('"""', index) or line.startswith("'''", index):
            state = line[index:index + 3]
            index += 3
        elif line[index] == '"':
            index += 1
            while index < len(line):
                if line[index] == '\\':
                    index += 2
                elif line[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
        elif line[index] == "'":
            index += 1
            while index < len(line) and line[index] != "'":
                index += 1
            if index < len(line):
                index += 1
        elif line[index] == '#':
            break
        else:
            index += 1
    return state

lines = re.findall(r'[^\n]*\n|[^\n]+\Z', text)
starts = []
offset = 0
state = None
for line in lines:
    starts.append((offset, state))
    state = next_string_state(line, state)
    offset += len(line)

match_index = None
header_indexes = []
for index, (line, (_, state_before)) in enumerate(zip(lines, starts)):
    if state_before is not None or not table_re.match(line):
        continue
    header_indexes.append(index)
    match = header_re.match(line)
    if match:
        candidate_config = tomllib.loads(match.group("header") + "\n__fm_marker = 1\n")
        candidate_projects = candidate_config.get("projects", {})
        if isinstance(candidate_projects, dict) and target in candidate_projects:
            match_index = index
if match_index is None:
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"\n{header}\ntrust_level = \"trusted\"\n"
else:
    section_end = len(lines)
    for index in header_indexes:
        if index > match_index:
            section_end = index
            break
    trust_index = None
    for index in range(match_index + 1, section_end):
        line, (_, state_before) = lines[index], starts[index]
        if state_before is None and re.match(r'^[ \t]*(?:trust_level|"trust_level"|\'trust_level\')[ \t]*=', line):
            trust_index = index
            break
    if trust_index is not None:
        end_index = trust_index + 1
        while end_index < section_end and starts[end_index][1] is not None:
            end_index += 1
        replacement = re.match(r'^([ \t]*)', lines[trust_index]).group(1) + 'trust_level = "trusted"\n'
        start = starts[trust_index][0]
        stop = starts[end_index][0] if end_index < len(starts) else len(text)
        text = text[:start] + replacement + text[stop:]
    else:
        insertion = starts[match_index][0] + len(lines[match_index])
        separator = "" if lines[match_index].endswith("\n") else "\n"
        text = text[:insertion] + separator + 'trust_level = "trusted"\n' + text[insertion:]

try:
    tomllib.loads(text)
except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
    raise SystemExit(f"refusing to write invalid Codex config: {exc}")

before = hashlib.sha256(original).digest()
current = store.read_bytes() if store.exists() else b""
if hashlib.sha256(current).digest() != before:
    raise SystemExit(f"Codex config '{store}' changed during trust registration; refusing to overwrite it")

mode = stat.S_IMODE(store.stat().st_mode) if store.exists() else 0o600
fd, staged = tempfile.mkstemp(prefix=".config.toml.fm-codex-trust.", dir=store.parent)
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(text)
    os.replace(staged, store)
except BaseException:
    try:
        os.unlink(staged)
    except FileNotFoundError:
        pass
    raise

check = tomllib.loads(store.read_text(encoding="utf-8"))
if check.get("projects", {}).get(target, {}).get("trust_level") != "trusted":
    raise SystemExit(f"Codex config '{store}' did not retain trust for '{target}'")
print(f"trusted: {target}")
PY
then
  refuse "Codex trust registration failed"
fi
