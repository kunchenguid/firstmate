#!/usr/bin/env bash
# Pre-register Pi's project-folder trust for the linked task worktree a pi or
# pi-signed spawn is about to launch into, so the worker reaches its brief
# instead of parking on Pi's interactive trust dialog.
#
# Usage: fm-pi-trust.sh <worktree> <project>
#   <worktree>  the isolated linked task worktree this spawn launches into
#   <project>   the checkout whose git common directory that worktree shares
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Pi 0.85.1 gates project-local resources in an unseen folder
# behind "Trust project folder?" before it processes the launch brief. Pi's
# --approve flag was verified to suppress that dialog for one run, but the
# durable trust store is the stronger spawn control: it is the same decision
# the dialog writes, and it does not depend on the launch flag keeping its
# current meaning. Pi records a flat JSON map in <agent-dir>/trust.json, where
# <agent-dir> is ${PI_CODING_AGENT_DIR} when set and ~/.pi/agent otherwise.
# bin/fm-spawn.sh forwards a set override onto the worker launch so this helper
# and the long-lived endpoint process use the same store.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh:
# <worktree> must be a LINKED git worktree - its own git dir, sharing
# <project>'s common dir - whose top level is exactly the resolved argument.
# Git is the ground truth. A primary checkout, a worktree of an unrelated repo,
# a subdirectory, a plain directory, and a home directory are each refused with
# a non-zero exit, never a warning or silent skip. This helper is for task
# worktrees only; Pi secondmate homes have a different structural shape and are
# not passed here.
#
# Only the launching user's own store is written. An existing store must resolve
# to a regular file this uid owns and can write. Every unrelated entry is
# preserved. The replacement uses an exclusive temp file and atomic rename,
# fingerprints the store immediately before that rename, retries one concurrent
# move, and confirms the worktree entry from a fresh read before reporting
# success. The fingerprint narrows but cannot eliminate the final race between
# the comparison and rename, the same limit documented by fm-claude-trust.sh.
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
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ "$WT_REAL" != / ] || refuse "'/' is the filesystem root, not a task worktree"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$WT_REAL" != "${HOME_REAL:-}" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"
fi

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

command -v node >/dev/null 2>&1 || refuse "node is required to record project trust and was not found on PATH"

# Pi accepts a relative PI_CODING_AGENT_DIR, but the worker resolves it from
# the task worktree while this helper starts elsewhere. That would put the trust
# store in project content, not the launching user's own config. Refuse that
# shape rather than guessing or writing into the worktree. Absolute and
# home-relative overrides resolve to the same store in both processes.
case ${PI_CODING_AGENT_DIR:-} in
  '' | /* | '~' | '~/'*) ;;
  *) refuse "PI_CODING_AGENT_DIR '$PI_CODING_AGENT_DIR' is a relative path, so it does not identify the launching user's own store; set it to an absolute or home-relative path" ;;
esac
AGENT_DIR=$(node - "${PI_CODING_AGENT_DIR:-}" <<'NODE'
const os = require("node:os");
const path = require("node:path");
const [override] = process.argv.slice(2);
let value;
if (override) {
  value = override === "~" ? os.homedir() : override.startsWith("~/") ? path.join(os.homedir(), override.slice(2)) : override;
} else {
  value = path.join(os.homedir(), ".pi", "agent");
}
process.stdout.write(path.resolve(value));
NODE
) || refuse "Pi's agent directory could not be resolved"

mkdir -p "$AGENT_DIR" 2>/dev/null || true
AGENT_DIR_REAL=$(real_dir "$AGENT_DIR") || true
[ -n "$AGENT_DIR_REAL" ] || refuse "Pi agent directory '$AGENT_DIR' does not exist and could not be created"
[ "$WT_REAL" != "$AGENT_DIR_REAL" ] || refuse "'$WT_REAL' is the Pi agent directory, not a task worktree"

STORE="$AGENT_DIR_REAL/trust.json"
# Follow an owned store symlink instead of replacing the link itself. A broken
# link or a target owned by another uid is refused.
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

if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, worktree] = process.argv.slice(2);
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
const parseStore = (buf) => {
  if (buf === null || buf.toString("utf8").trim() === "") return {};
  const root = JSON.parse(buf.toString("utf8").replace(/^\uFEFF/, ""));
  if (root === null || typeof root !== "object" || Array.isArray(root)) {
    throw new Error(`${store} is not a JSON object`);
  }
  return root;
};
const landed = () => parseStore(readStore())[worktree] === true;
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  const root = parseStore(original);
  if (root[worktree] === true) return "recorded";
  root[worktree] = true;
  const sorted = {};
  for (const key of Object.keys(root).sort()) sorted[key] = root[key];
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.trust.json.fm-trust.${unique}`);
  fs.writeFileSync(tmp, `${JSON.stringify(sorted, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  return landed() ? "recorded" : "dropped";
};
try {
  for (let attemptNumber = 0; attemptNumber < 2; attemptNumber += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && attemptNumber === 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${worktree} after 2 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
