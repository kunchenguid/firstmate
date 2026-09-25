#!/usr/bin/env bash
# Manage T3's overlay on a tracked .codex/config.toml.
# Usage: fm-t3code-codex-env.sh check|install|cleanup <worktree> [NAME=VALUE...]
# check validates tracked TOML and refuses an existing shell_environment_policy
# table before spawn leases a slot. install rechecks the actual launch directory,
# saves original/installed bytes in its private Git directory, sets skip-worktree,
# then appends the policy. Ordinary git add/commit therefore keep the index's
# project config. Do not clear skip-worktree or edit this file while it is leased.
# cleanup restores the original bytes and prior skip-worktree flag before pool
# return. The journal is published before either mutation and removed last, so
# interrupted install/cleanup is recoverable. Unexpected file or index edits
# refuse cleanup rather than discard work. An untracked config has no journal
# and is removed, preserving the original channel's cleanup behavior.
# Only tracked overlays need Python 3.11+ (tomllib); untracked install remains
# owned by spawn_t3code_env_install in fm-spawn.sh. The first interpreter that
# imports tomllib is used, so a stock macOS python3 (3.9) is passed over when a
# newer python3.N is installed beside it.
set -eu

case "${1:-}" in
  check|install|cleanup) ;;
  *) echo "usage: fm-t3code-codex-env.sh check|install|cleanup <worktree> [NAME=VALUE...]" >&2; exit 1 ;;
esac
ACTION=$1
WT=${2:?worktree required}
shift 2
GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || {
  [ "$ACTION" = cleanup ] || exit 1
  rm -f "$WT/.codex/config.toml"
  exit 0
}
JOURNAL="$GIT_DIR/fm-t3code-codex-env.json"
if [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ] \
    && ! git -C "$WT" ls-files --error-unmatch .codex/config.toml >/dev/null 2>&1; then
  [ "$ACTION" != cleanup ] || rm -f "$WT/.codex/config.toml"
  exit 0
fi

PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON=$candidate
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "error: $WT/.codex/config.toml: Python 3.11+ with tomllib is required to validate tracked configuration" >&2
  exit 1
fi

"$PYTHON" - "$ACTION" "$WT" "$JOURNAL" "$@" <<'PY'
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

action, root, journal_name, *pairs = sys.argv[1:]
relative = ".codex/config.toml"
file = Path(root) / relative
journal = Path(journal_name)


def refuse(message):
    sys.exit(f"error: {file}: {message}")


def git(*args, **kwargs):
    return subprocess.check_output(["git", "-C", root, *args], **kwargs)


def atomic_write(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if file.parent.is_symlink() or file.is_symlink() or journal.is_symlink():
    refuse("refusing a symlink in the tracked Codex environment channel")

if journal.exists():
    record = json.loads(journal.read_bytes())
    original = base64.b64decode(record["original"], validate=True)
    installed = base64.b64decode(record["installed"], validate=True)
    if git("ls-files", "--stage", "--", relative).decode() != record["index"]:
        refuse("index changed while the Firstmate overlay was installed; preserve the journal and reconcile configuration before cleanup")
    if not file.is_file() or file.read_bytes() not in (original, installed):
        refuse("configuration changed while the Firstmate overlay was installed; preserve the journal and reconcile configuration before cleanup")
    if action == "cleanup":
        atomic_write(file, original, record["mode"])
        git("update-index", "--skip-worktree" if record["skip"] else "--no-skip-worktree", "--", relative)
        journal.unlink()
        sys.exit(0)
    if action == "install":
        refuse("a Firstmate environment overlay is already installed; run cleanup before installing another")
else:
    if action == "cleanup":
        # A tracked project file without our journal belongs entirely to Git.
        sys.exit(0)
    original = file.read_bytes()

import tomllib
try:
    config = tomllib.loads(original.decode("utf-8"))
except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
    refuse(f"invalid TOML: {error}")
if "shell_environment_policy" in config:
    refuse("already defines [shell_environment_policy]; refusing to replace the project's policy table")
if action == "check":
    sys.exit(0)

index = git("ls-files", "--stage", "--", relative).decode()
entries = index.splitlines()
if len(entries) != 1 or entries[0].split()[0] not in ("100644", "100755") or entries[0].split()[2] != "0":
    refuse("tracked configuration must be a regular, unconflicted file")
blob = git("hash-object", f"--path={relative}", "--stdin", input=original).decode().strip()
if blob != entries[0].split()[1] or subprocess.call(["git", "-C", root, "diff", "--cached", "--quiet", "HEAD", "--", relative]) != 0:
    refuse("tracked configuration has uncommitted changes; refusing to hide them with skip-worktree")
env = dict(pair.split("=", 1) for pair in pairs)
table = ", ".join(f"{json.dumps(key)} = {json.dumps(value, ensure_ascii=False)}" for key, value in env.items())
installed = original + f"\n[shell_environment_policy]\nset = {{ {table} }}\n".encode()
tomllib.loads(installed.decode("utf-8"))
record = {
    "original": base64.b64encode(original).decode(),
    "installed": base64.b64encode(installed).decode(),
    "index": index,
    "mode": file.stat().st_mode & 0o777,
    "skip": git("ls-files", "-v", "--", relative)[:1].upper() == b"S",
}
atomic_write(journal, json.dumps(record).encode(), 0o600)
git("update-index", "--skip-worktree", "--", relative)
atomic_write(file, installed, record["mode"])
PY
