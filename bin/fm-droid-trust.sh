#!/usr/bin/env bash
# Register or retire Droid folder trust for exactly an isolated task worktree.
# Usage: fm-droid-trust.sh [--remove] <worktree> <project>
# --remove retires only those exact paths before teardown returns the worktree.
# The worktree must be a linked worktree of that project, never its primary
# checkout, a parent, or the user's home. Only the exact logical and physical
# worktree paths enter ~/.factory/settings.json trustedFolders. Other settings
# and existing trust entries are preserved; malformed or racing stores refuse.
# Verified on Droid 0.237.0; runtime --settings trust entries are not sufficient.
# This helper owns trust mutation; spawn and teardown refuse if it fails.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

ACTION=register
if [ "${1:-}" = --remove ]; then ACTION=remove; shift; fi
[ "$#" -eq 2 ] || { echo "usage: fm-droid-trust.sh [--remove] <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to change Droid trust: $1" >&2; exit 1; }

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

[ -n "${HOME:-}" ] || refuse "HOME is not set, so Droid's settings store cannot be located"
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

command -v node >/dev/null 2>&1 || refuse "node is required to change workspace trust and was not found on PATH"

STORE_DIR="$HOME_REAL/.factory"
[ "$ACTION" != remove ] || [ -e "$STORE_DIR/settings.json" ] || [ -L "$STORE_DIR/settings.json" ] || exit 0
mkdir -p "$STORE_DIR" 2>/dev/null || true
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] || refuse "Droid settings directory '$STORE_DIR' does not exist and could not be created"
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

# Read-modify-write with a fingerprint check before rename and readback:
# Droid itself rewrites this file
# when a worker answers a dialog or changes a setting, so a store that moved
# under us is retried once and then refused rather than clobbered.
if ! node - "$STORE" "$ACTION" "$WT_LOGICAL" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, action, ...wanted] = process.argv.slice(2);
const paths = [...new Set(wanted)];
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const parseSettings = (raw) => {
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error(`${store} contains invalid JSON`);
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const validEntry = (entry) =>
  entry !== null && typeof entry === "object" && !Array.isArray(entry) && typeof entry.trustedAt === "string" && entry.trustedAt.length > 0;
const listed = (root) =>
  root.trustedFolders !== null && typeof root.trustedFolders === "object" && !Array.isArray(root.trustedFolders) && paths.every((p) => Object.prototype.hasOwnProperty.call(root.trustedFolders, p) && validEntry(root.trustedFolders[p]));
const satisfied = (root) => action === "remove"
  ? paths.every((p) => !Object.prototype.hasOwnProperty.call(root.trustedFolders || {}, p))
  : listed(root);
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = parseSettings(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.trustedFolders === undefined || root.trustedFolders === null) root.trustedFolders = {};
  if (typeof root.trustedFolders !== "object" || Array.isArray(root.trustedFolders)) {
    throw new Error(`${store} has a non-object "trustedFolders" value`);
  }
  for (const p of paths) {
    if (Object.prototype.hasOwnProperty.call(root.trustedFolders, p) && !validEntry(root.trustedFolders[p])) {
      throw new Error(`${store} has an invalid trusted-folder entry for ${p}`);
    }
  }
  if (satisfied(root)) return "recorded";
  for (const p of paths) {
    if (action === "remove") {
      delete root.trustedFolders[p];
    } else if (!Object.prototype.hasOwnProperty.call(root.trustedFolders, p)) {
      root.trustedFolders[p] = { trustedAt: new Date().toISOString() };
    }
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
  return satisfied(parseSettings(fs.readFileSync(store, "utf8"))) ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being changed; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain the requested trust ${action} for ${paths.join(", ")} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not change trust for '$WT_LOGICAL' in '$STORE'"
fi

if [ "$ACTION" = remove ]; then
  echo "untrusted: $WT_REAL"
elif [ "$WT_LOGICAL" != "$WT_REAL" ]; then
  echo "trusted: $WT_LOGICAL ($WT_REAL)"
else
  echo "trusted: $WT_REAL"
fi
