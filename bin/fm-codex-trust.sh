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

command -v python3 >/dev/null 2>&1 || refuse "python3 is required to validate Codex config.toml"

CONFIG_ROOT=${CODEX_HOME:-${HOME:-}/.codex}
[ -n "$CONFIG_ROOT" ] || refuse "neither CODEX_HOME nor HOME is set"
case "$CONFIG_ROOT" in
  /*) ;;
  *) refuse "CODEX_HOME must be an absolute path" ;;
esac
mkdir -p "$CONFIG_ROOT" || refuse "could not create Codex config directory '$CONFIG_ROOT'"
CONFIG_ROOT=$(real_dir "$CONFIG_ROOT") || refuse "Codex config directory '$CONFIG_ROOT' could not be resolved"
STORE="$CONFIG_ROOT/config.toml"
if [ -L "$STORE" ]; then
  STORE=$(python3 - "$STORE" <<'PY'
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

if ! python3 - "$STORE" "$TARGET_REAL" <<'PY'
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
original = store.read_bytes() if store.exists() else b""
try:
    parsed = tomllib.loads(original.decode())
except tomllib.TOMLDecodeError as exc:
    raise SystemExit(f"Codex config '{store}' is invalid TOML: {exc}")

projects = parsed.get("projects", {})
entry = projects.get(target, {}) if isinstance(projects, dict) else {}
if isinstance(entry, dict) and entry.get("trust_level") == "trusted":
    print(f"trusted: {target} (already registered)")
    raise SystemExit(0)

text = original.decode() if original else ""
escaped = target.replace("\\", "\\\\").replace('"', '\\"')
header = f'[projects."{escaped}"]'
header_re = re.compile(r'^(?P<header>\[projects\.(?:"(?:[^"\\]|\\.)*"|\'[^\']*\')\])[ \t]*(?:#.*)?$', re.MULTILINE)
table_re = re.compile(r'^\[\[?[^\n]+\]\]?[ \t]*(?:#.*)?$', re.MULTILINE)
match = None
for candidate in header_re.finditer(text):
    candidate_config = tomllib.loads(candidate.group("header") + "\n__fm_marker = 1\n")
    candidate_projects = candidate_config.get("projects", {})
    if isinstance(candidate_projects, dict) and target in candidate_projects:
        match = candidate
        break
if match is None:
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"\n{header}\ntrust_level = \"trusted\"\n"
else:
    end = table_re.search(text, match.end())
    section_end = end.start() if end else len(text)
    section = text[match.end():section_end]
    trust = re.search(r'(?m)^[ \t]*trust_level[ \t]*=[^\n]*$', section)
    if trust:
        start = match.end() + trust.start()
        stop = match.end() + trust.end()
        text = text[:start] + 'trust_level = "trusted"' + text[stop:]
    else:
        insertion = match.end()
        if text[insertion:insertion + 1] == "\n":
            insertion += 1
        text = text[:insertion] + 'trust_level = "trusted"\n' + text[insertion:]

try:
    tomllib.loads(text)
except tomllib.TOMLDecodeError as exc:
    raise SystemExit(f"refusing to write invalid Codex config: {exc}")

before = hashlib.sha256(original).digest()
current = store.read_bytes() if store.exists() else b""
if hashlib.sha256(current).digest() != before:
    raise SystemExit(f"Codex config '{store}' changed during trust registration; refusing to overwrite it")

mode = stat.S_IMODE(store.stat().st_mode) if store.exists() else 0o600
store.parent.mkdir(parents=True, exist_ok=True)
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
