#!/usr/bin/env bash
# Pre-register Pi's workspace trust for the exact isolated task worktree a Pi
# or Pi-signed crewmate or scout spawn is about to enter. Pi stores trust as a
# path-to-boolean map in ~/.pi/agent/trust.json; this helper adds only the
# requested worktree and preserves every existing entry.
#
# Usage: fm-pi-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses anything else.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 2 ] || { echo "usage: fm-pi-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register Pi trust: $1" >&2; exit 1; }
real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
[ -n "${HOME:-}" ] || refuse "HOME is not set, so Pi's trust store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
[ "$WT_REAL" != / ] || refuse "'/' is not a task worktree"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root"
WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
WT_GIT_DIR=$(real_dir "${WT_GIT_DIR:-}") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"
PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"
STORE_DIR="$HOME_REAL/.pi/agent"
mkdir -p "$STORE_DIR" 2>/dev/null || true
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] || refuse "Pi trust directory '$STORE_DIR' does not exist and could not be created"
STORE="$STORE_DIR_REAL/trust.json"
if [ -L "$STORE" ]; then
  STORE_REAL=$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$STORE" 2>/dev/null) || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, target] = process.argv.slice(2);
const readStore = () => {
  try { return fs.readFileSync(store); }
  catch (err) { if (err.code === "ENOENT") return null; throw err; }
};
const fingerprint = (buf) => buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null && original.toString("utf8").trim() !== "") {
    root = JSON.parse(original.toString("utf8"));
    if (root === null || typeof root !== "object" || Array.isArray(root)) throw new Error(`${store} is not a JSON object`);
  }
  if (root[target] === true) return "recorded";
  root[target] = true;
  const tmp = path.join(path.dirname(store), `.trust.json.fm-trust.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store); renamed = true;
  } finally { if (!renamed) fs.rmSync(tmp, { force: true }); }
  return JSON.parse(fs.readFileSync(store, "utf8"))[target] === true ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) throw new Error(`${store} was modified while trust was being recorded`);
  }
  throw new Error(`${store} did not retain trust for ${target} after 3 attempts`);
} catch (err) { console.error(`error: ${err.message}`); process.exit(1); }
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
