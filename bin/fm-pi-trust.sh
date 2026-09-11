#!/usr/bin/env bash
# Pre-register Pi's project trust for an isolated task worktree before launch.
#
# Usage: fm-pi-trust.sh <worktree> <project>
#   <worktree>  the isolated worktree Pi will open
#   <project>   the primary checkout that owns the worktree
#
# Pi stores decisions in ${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/trust.json
# as a JSON object mapping canonical directory paths to true, false, or null.
# This command adds the exact worktree path as true and refuses every path that
# is not a linked worktree of the supplied project.
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

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root"
WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"
PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

command -v node >/dev/null 2>&1 || refuse "node is required to record Pi trust and was not found on PATH"

AGENT_DIR=${PI_CODING_AGENT_DIR:-}
if [ -z "$AGENT_DIR" ]; then
  [ -n "${HOME:-}" ] || refuse "neither PI_CODING_AGENT_DIR nor HOME is set"
  AGENT_DIR=$HOME/.pi/agent
else
  case "$AGENT_DIR" in
    '~')
      [ -n "${HOME:-}" ] || refuse "PI_CODING_AGENT_DIR uses ~ but HOME is not set"
      AGENT_DIR=$HOME
      ;;
    \~/*)
      [ -n "${HOME:-}" ] || refuse "PI_CODING_AGENT_DIR uses ~ but HOME is not set"
      AGENT_DIR=$HOME/${AGENT_DIR#~/}
      ;;
    /*) ;;
    *) refuse "PI_CODING_AGENT_DIR '$AGENT_DIR' is a relative path" ;;
  esac
fi
AGENT_REAL=$(real_dir "$AGENT_DIR") || true
if [ -z "$AGENT_REAL" ]; then
  mkdir -p -- "$AGENT_DIR" 2>/dev/null || true
  AGENT_REAL=$(real_dir "$AGENT_DIR") || true
fi
[ -n "$AGENT_REAL" ] || refuse "Pi config directory '$AGENT_DIR' does not exist and could not be created"
[ -d "$AGENT_REAL" ] && [ -O "$AGENT_REAL" ] && [ -w "$AGENT_REAL" ] \
  || refuse "Pi config directory '$AGENT_REAL' is not a writable directory owned by this user"
[ "$WT_REAL" != "$AGENT_REAL" ] || refuse "'$WT_REAL' is the Pi config directory, not a task worktree"

STORE="$AGENT_REAL/trust.json"
if [ -L "$STORE" ]; then
  STORE=$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$STORE" 2>/dev/null) \
    || refuse "'$STORE' is a symlink whose target cannot be resolved"
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# The vendor also writes this whole JSON file. Fingerprinting before the atomic
# rename avoids overwriting a concurrent vendor update; three attempts are
# enough for a short spawn-time registration, otherwise fail closed.
# ponytail: fingerprint-and-refuse leaves a tiny rename race; a shared lock would
# add a dependency and cannot coordinate versions of Pi that do not use it.
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, worktree] = process.argv.slice(2);
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
};
const fingerprint = (bytes) =>
  bytes === null ? "absent" : crypto.createHash("sha256").update(bytes).digest("hex");
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  const data = original === null || original.toString("utf8").trim() === ""
    ? {}
    : JSON.parse(original.toString("utf8"));
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    throw new Error(`${store} is not a JSON object`);
  }
  for (const [key, value] of Object.entries(data)) {
    if (value !== true && value !== false && value !== null) {
      throw new Error(`${store} has an invalid decision for ${JSON.stringify(key)}`);
    }
  }
  data[worktree] = true;
  const sorted = {};
  for (const key of Object.keys(data).sort()) sorted[key] = data[key];
  const tmp = path.join(path.dirname(store), `.trust.json.fm-pi.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
  fs.writeFileSync(tmp, `${JSON.stringify(sorted, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return back[worktree] === true ? "recorded" : "dropped";
};
try {
  for (let attemptNumber = 0; attemptNumber < 3; attemptNumber += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && attemptNumber === 2) {
      console.error(`error: ${store} was modified while Pi trust was being recorded`);
      process.exit(1);
    }
  }
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${worktree}`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
