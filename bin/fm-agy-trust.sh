#!/usr/bin/env bash
# Pre-register Antigravity CLI's workspace trust for the isolated task worktree
# a ship/scout spawn is about to launch an agy crewmate into, so the worker
# reaches its brief in the worktree instead of parking on the folder-trust
# dialog and running its turn in agy's own scratch directory.
#
# Usage: fm-agy-trust.sh <worktree> <project> [agy-bin]
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   [agy-bin]   selected executable; required to resolve Windows agy under WSL
# Native launches (including an omitted agy-bin) use
# ${HOME}/.gemini/antigravity-cli/settings.json and native worktree paths.
# A selected PE executable uses %USERPROFILE%\.gemini\antigravity-cli\settings.json
# and wslpath-translated Windows/UNC worktree paths, not the Linux store.
# Resolve cmd.exe from PATH, then the conventional C:\Windows\System32 path
# through wslpath; bound the USERPROFILE probe to 5 seconds and refuse an
# unprovable Windows home, leaving the spawn's dialog backstop in charge.
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. agy 1.2.0 gates a folder it has never seen behind
# "Do you trust the contents of this project?" and no launch flag suppresses
# it (`agy --help` lists none). Answering appends the folder to the
# `trustedWorkspaces` array of the selected profile's settings store.
# Native-Linux dialog suppression and logical-cwd comparison were verified
# live; docs/verification/agy.md owns that evidence and the Windows limits.
# Both the logical path and its resolved form are recorded when they differ.
#
# bin/fm-spawn.sh keeps a post-launch gate as the backstop: it answers the
# dialog if one renders anyway and never counts a busy turn as ready on a path
# that was neither pre-registered here nor answered there.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh:
# <worktree> must be a LINKED git worktree - its own git dir, sharing
# <project>'s common dir - whose top level is exactly the resolved argument. A
# primary checkout, a worktree of an unrelated repo, a subdirectory of a
# worktree, a plain directory, and a home directory are each refused with a
# non-zero exit, never a warning and never a silent skip. Only the launching
# user's own store is written, it must be a regular file this uid owns, every
# unrelated key and entry is preserved, and the replacement is atomic.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "usage: fm-agy-trust.sh <worktree> <project> [agy-bin]" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2
AGY_BIN=${3:-}

refuse() { echo "error: refusing to pre-register agy trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
logical_dir() { (cd -- "$1" 2>/dev/null && pwd -L); }
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
WT_LOGICAL=$(logical_dir "$WT_ARG") || true
[ -n "$WT_LOGICAL" ] || WT_LOGICAL=$WT_REAL
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so agy's settings store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

TRUST_PATHS=("$WT_LOGICAL" "$WT_REAL")
STORE_HOME=$HOME_REAL
# Inspect the executable format, never its suffix or symlink name: PATH may
# expose a Windows agy.exe as the bare word agy. Keep the git scope test above
# on Linux paths before translating anything or touching either profile.
AGY_FORMAT=native
if [ -n "$AGY_BIN" ]; then
  AGY_FORMAT=$(node - "$AGY_BIN" <<'NODE'
const fs = require('node:fs');
const fd = fs.openSync(process.argv[2], 'r');
const magic = Buffer.alloc(2);
const n = fs.readSync(fd, magic, 0, 2, 0);
fs.closeSync(fd);
console.log(n === 2 && magic.toString('ascii') === 'MZ' ? 'windows' : 'native');
NODE
  ) || refuse "could not inspect the selected agy executable"
fi
if [ "$AGY_FORMAT" = windows ]; then
  command -v wslpath >/dev/null 2>&1 || refuse "Windows agy requires wslpath to locate its settings store"
  CMD_BIN=$(command -v cmd.exe 2>/dev/null) || CMD_BIN=$(wslpath -u 'C:\Windows\System32\cmd.exe' 2>/dev/null) || true
  [ -n "${CMD_BIN:-}" ] && [ -x "$CMD_BIN" ] || refuse "Windows agy requires cmd.exe to resolve its USERPROFILE"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"
  # Read the environment listing in UTF-16LE rather than expanding the value
  # into a command: profile names may contain Unicode or cmd metacharacters.
  WIN_HOME=$(
    set -o pipefail
    fm_run_timed 5 "$CMD_BIN" /d /u /c 'set USERPROFILE' </dev/null 2>/dev/null |
      node -e 'const lines = require("node:fs").readFileSync(0).toString("utf16le").split(/\r?\n/); const profile = lines.find(line => /^USERPROFILE=/i.test(line)); if (profile === undefined) process.exit(1); process.stdout.write(profile.slice("USERPROFILE=".length));'
  ) || refuse "could not resolve Windows agy's USERPROFILE within 5 seconds"
  case "$WIN_HOME" in
    [a-zA-Z]:\\* | \\\\*) ;;
    *) refuse "cmd.exe did not return an absolute Windows USERPROFILE" ;;
  esac
  STORE_HOME=$(wslpath -u "$WIN_HOME" 2>/dev/null) || refuse "could not translate Windows agy's USERPROFILE"
  STORE_HOME=$(real_dir "$STORE_HOME") || refuse "Windows agy's USERPROFILE is not an accessible directory"
  WIN_LOGICAL=$(wslpath -w "$WT_LOGICAL" 2>/dev/null) || refuse "could not translate the logical worktree path for Windows agy"
  WIN_REAL=$(wslpath -w "$WT_REAL" 2>/dev/null) || refuse "could not translate the resolved worktree path for Windows agy"
  [ -n "$WIN_LOGICAL" ] && [ -n "$WIN_REAL" ] || refuse "wslpath returned an empty Windows worktree path"
  TRUST_PATHS=("$WIN_LOGICAL" "$WIN_REAL")
fi

STORE_DIR="$STORE_HOME/.gemini/antigravity-cli"
mkdir -p "$STORE_DIR" 2>/dev/null || true
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] || refuse "agy settings directory '$STORE_DIR' does not exist and could not be created"
STORE="$STORE_DIR_REAL/settings.json"
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write with a fingerprint check before the rename and a readback
# after it, the bin/fm-claude-trust.sh shape: agy itself rewrites this file
# when a worker answers a dialog or changes a setting, so a store that moved
# under us is retried once and then refused rather than clobbered.
if ! node - "$STORE" "${TRUST_PATHS[@]}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, ...wanted] = process.argv.slice(2);
const paths = [...new Set(wanted)];
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const listed = (root) =>
  Array.isArray(root.trustedWorkspaces) && paths.every((p) => root.trustedWorkspaces.includes(p));
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.trustedWorkspaces === undefined || root.trustedWorkspaces === null) root.trustedWorkspaces = [];
  if (!Array.isArray(root.trustedWorkspaces)) {
    throw new Error(`${store} has a non-array "trustedWorkspaces" value`);
  }
  if (listed(root)) return "recorded";
  for (const p of paths) {
    if (!root.trustedWorkspaces.includes(p)) root.trustedWorkspaces.push(p);
  }
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.settings.json.fm-trust.${unique}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  return listed(JSON.parse(fs.readFileSync(store, "utf8"))) ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${paths.join(", ")} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_LOGICAL' in '$STORE'"
fi

if [ "$WT_LOGICAL" != "$WT_REAL" ]; then
  echo "trusted: $WT_LOGICAL ($WT_REAL)"
else
  echo "trusted: $WT_REAL"
fi
