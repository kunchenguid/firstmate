#!/usr/bin/env bash
# Pre-register Bob CLI's workspace trust for the isolated task worktree a ship
# or scout spawn is about to launch a bob crewmate into, so the worker reaches
# its brief in the worktree instead of being blocked by --auto-approve silently
# refusing to auto-approve in an untrusted folder.
#
# Usage: fm-bob-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Bob CLI 2.0.9's --auto-approve flag is conditional on
# trust: in an untrusted folder it is silently suppressed, so tool executions
# prompt for approval and the worker parks on approval dialogs firstmate
# cannot answer. Bob's trust store is ~/.bob/trustedFolders.json; its schema
# is { "version": 1, "folders": { "<path>": "TRUST_FOLDER" } }. Answering
# the --trust flag on the launch command also writes this store, but a pane
# can wedge on a trust dialog before --trust persists, so pre-registration
# is the only control that reliably reaches an interactive pane. Additionally,
# Bob's workspace hooks (.bob/settings.json) are silently skipped in untrusted
# folders: pre-registration is a prerequisite for those hooks firing at all.
#
# Analogous to bin/fm-agy-trust.sh (the same read-modify-write-with-fingerprint
# node pattern, the same scope test, the same refusal semantics).
# bin/fm-spawn.sh treats a failed registration as fatal: unlike agy, where the
# launch-readiness gate can answer the trust dialog itself, bob's auto-approve
# suppression is silent and workspace hooks silently skip, so a failed
# registration is not a recoverable condition.
#
# THE SCOPE TEST mirrors bin/fm-agy-trust.sh:
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

usage() {
  echo "usage: fm-bob-trust.sh <worktree> <project>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
case "$1" in '' | -h | --help) usage ;; esac
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register bob trust: $1" >&2; exit 1; }

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

[ -n "${HOME:-}" ] || refuse "HOME is not set, so bob's trust store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
[ "$WT_REAL" != / ] || refuse "'/' is the filesystem root, not a worktree"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a worktree"

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

STORE_DIR="$HOME_REAL/.bob"
mkdir -p "$STORE_DIR" 2>/dev/null || true
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] || refuse "bob config directory '$STORE_DIR' does not exist and could not be created"
STORE="$STORE_DIR_REAL/trustedFolders.json"
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
# after it, the bin/fm-agy-trust.sh / bin/fm-claude-trust.sh shape: bob itself
# rewrites this file when a worker answers a trust prompt or the user trusts a
# folder interactively, so a store that moved under us is retried once and then
# refused rather than clobbered.
# Bob's store schema: { "version": 1, "folders": { "<path>": "TRUST_FOLDER" } }
# "TRUST_FOLDER" = the exact folder is trusted; "TRUST_PARENT" = all children
# are trusted. We register as TRUST_FOLDER for the isolated worktree: the exact
# path, no more (parent trust would cover sibling worktrees and is too broad).
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, wantedPath] = process.argv.slice(2);
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
const isTrusted = (root) =>
  root.folders &&
  typeof root.folders === "object" &&
  !Array.isArray(root.folders) &&
  (root.folders[wantedPath] === "TRUST_FOLDER" ||
   root.folders[wantedPath] === "TRUST_PARENT");
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = { version: 1, folders: {} };
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (!root.folders || typeof root.folders !== "object" || Array.isArray(root.folders)) {
    root.folders = {};
  }
  if (isTrusted(root)) return "recorded";
  root.folders[wantedPath] = "TRUST_FOLDER";
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.trustedFolders.json.fm-trust.${unique}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  return isTrusted(JSON.parse(fs.readFileSync(store, "utf8"))) ? "recorded" : "dropped";
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
console.error(`error: ${store} did not retain trust for ${wantedPath} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
