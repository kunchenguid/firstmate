#!/usr/bin/env bash
# Register or retire Droid folder trust for exactly an isolated task worktree.
# Usage: fm-droid-trust.sh [--receipt <file>] [--remove] <worktree> <project>
#        fm-droid-trust.sh --rollback <receipt>
#        fm-droid-trust.sh --retire <receipt> <state> <task-id>
# Receipts retain exact paths across relaunch and worktree removal. Rollback
# removes only unchanged entries acquired by registration. Retirement transfers
# cleanup to another recorded task using the path, or removes only those paths.
# All Firstmate mutations serialize at the resolved Factory settings store.
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
RECEIPT=
TASK_STATE=
TASK_ID=
if [ "${1:-}" = --receipt ]; then RECEIPT=${2:-}; shift 2; fi
case "${1:-}" in
  --remove) ACTION=remove; shift ;;
  --rollback) ACTION=rollback; RECEIPT=${2:-}; shift 2 ;;
  --retire) ACTION=retire; RECEIPT=${2:-}; TASK_STATE=${3:-}; TASK_ID=${4:-}; shift 4 ;;
esac
case "$ACTION" in
  rollback|retire) [ "$#" -eq 0 ] && [ -n "$RECEIPT" ] || exit 2; WT_ARG=; PROJ_ARG= ;;
  *) [ "$#" -eq 2 ] || { echo "usage: fm-droid-trust.sh [--receipt <file>] [--remove] <worktree> <project>" >&2; exit 2; }; WT_ARG=$1; PROJ_ARG=$2 ;;
esac

refuse() { echo "error: refusing to change Droid trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
logical_dir() { (cd -- "$1" 2>/dev/null && pwd -L); }
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

[ -n "${HOME:-}" ] || refuse "HOME is not set"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME is not an accessible directory"
WT_REAL=
WT_LOGICAL=
if [ "$ACTION" = register ] || [ "$ACTION" = remove ]; then
WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
WT_LOGICAL=$(logical_dir "$WT_ARG") || true
[ -n "$WT_LOGICAL" ] || WT_LOGICAL=$WT_REAL
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

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

fi

command -v node >/dev/null 2>&1 || refuse "node is required to change workspace trust and was not found on PATH"

STORE_DIR="$HOME_REAL/.factory"
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

# The lock covers reading settings, receipt publication, and atomic rename.
# Keep the wake library's source-time directory creation inside the store.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE=$STORE_DIR_REAL
FM_STATE_OVERRIDE=$STORE_DIR_REAL
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
STORE_LOCK="$STORE.fm-trust.lock"
fm_lock_acquire_wait_max "$STORE_LOCK" 10 || refuse "settings lock is busy: $STORE_LOCK"
trap 'fm_lock_release "$STORE_LOCK"' EXIT
trap 'exit 1' HUP INT TERM
if ! node - "$STORE" "$ACTION" "$RECEIPT" "$TASK_STATE" "$TASK_ID" "$WT_LOGICAL" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, action, receiptFile, state, id, logical, physical] = process.argv.slice(2);
const read = (file) => {
  try { return fs.readFileSync(file, "utf8"); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
};
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const parse = (raw, file) => {
  try { const root = JSON.parse(raw); if (!object(root)) throw new Error(); return root; }
  catch { throw new Error(`${file} is not a valid JSON object`); }
};
const atomic = (file, value) => {
  const tmp = `${file}.fm-trust.${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  try {
    fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, {mode:0o600, flag:"wx"});
    fs.renameSync(tmp, file);
  } finally { fs.rmSync(tmp, {force:true}); }
};
const receipt = (file) => {
  try { if (!fs.lstatSync(file).isFile()) throw new Error(`${file} is not a regular receipt`); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  const raw = read(file);
  const value = parse(raw, file);
  if (value.schema !== "fm-droid-trust.v1" || value.store !== store || !Array.isArray(value.paths)
      || !value.paths.every(p => typeof p === "string" && path.isAbsolute(p)) || !object(value.acquired)) {
    throw new Error(`${file} is not a valid Droid trust receipt`);
  }
  return value;
};
const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
const canonical = p => { try { return fs.realpathSync(p); } catch { return path.resolve(p); } };
try {
  let owned = receiptFile ? receipt(receiptFile) : null;
  if ((action === "rollback" || action === "retire") && !owned) process.exit(0);
  let paths = owned ? owned.paths : [...new Set([logical, physical])];
  if (action === "retire") {
    if (!/^[A-Za-z0-9._-]+$/.test(id) || path.resolve(receiptFile) !== path.join(path.resolve(state), `${id}.droid-trust`)) {
      throw new Error("retirement receipt does not match its task");
    }
    // A recorded task still owns its copy until retirement. Conservatively
    // transfer to it, including an exited or non-Droid successor, rather than
    // revoking a grant while another task may still use the same pooled path.
    for (const name of fs.readdirSync(state).sort()) {
      if (!name.endsWith(".meta") || name === `${id}.meta`) continue;
      const other = name.slice(0, -5);
      if (!/^[A-Za-z0-9._-]+$/.test(other)) continue;
      const meta = read(path.join(state, name));
      if (meta === null) continue;
      const wt = meta.split("\n").find(line => line.startsWith("worktree="))?.slice(9);
      if (!wt || !paths.some(p => p === wt || canonical(p) === canonical(wt))) continue;
      const nextFile = path.join(state, `${other}.droid-trust`);
      const next = receipt(nextFile);
      atomic(nextFile, {schema:"fm-droid-trust.v1", store,
        paths:[...new Set([...paths, ...(next?.paths || [])])],
        acquired:{...owned.acquired, ...(next?.acquired || {})}});
      fs.unlinkSync(receiptFile);
      process.exit(0);
    }
  }
  for (let attempt = 0; attempt < 3; attempt++) {
    const original = read(store);
    const root = original === null || original.trim() === "" ? {} : parse(original, store);
    if (root.trustedFolders == null) root.trustedFolders = {};
    if (!object(root.trustedFolders)) throw new Error(`${store} has a non-object trustedFolders value`);
    const folders = root.trustedFolders;
    if (action === "register") {
      paths = [...new Set([...paths, logical, physical])];
      const acquired = {...(owned?.acquired || {})};
      for (const p of [logical, physical]) {
        if (Object.hasOwn(folders, p)) {
          if (!object(folders[p]) || typeof folders[p].trustedAt !== "string" || !folders[p].trustedAt) {
            throw new Error(`${store} has an invalid trusted-folder entry for ${p}`);
          }
        } else {
          folders[p] = {trustedAt:new Date().toISOString()};
          acquired[p] = folders[p];
        }
      }
      owned = {schema:"fm-droid-trust.v1", store, paths, acquired};
      if (receiptFile) atomic(receiptFile, owned);
    } else {
      for (const p of paths) {
        if (action !== "rollback" || (Object.hasOwn(owned.acquired, p) && same(folders[p], owned.acquired[p]))) delete folders[p];
      }
    }
    if (read(store) !== original) continue;
    const changed = original === null ? action === "register"
      : !same(original.trim() ? parse(original, store) : {}, root);
    if (changed) atomic(store, root);
    const after = parse(read(store) || "{}", store).trustedFolders || {};
    const retained = action === "register" ? [logical, physical].every(p => same(after[p], folders[p]))
      : paths.every(p => action === "rollback" ? !same(after[p], owned.acquired[p]) || !Object.hasOwn(after,p) : !Object.hasOwn(after,p));
    if (!retained) continue;
    if (action !== "register" && receiptFile) fs.unlinkSync(receiptFile);
    process.exit(0);
  }
  throw new Error(`${store} changed during the trust transaction`);
} catch (error) { console.error(`error: ${error.message}`); process.exit(1); }
NODE
then
  refuse "could not complete $ACTION in $STORE; any receipt is retained for recovery"
fi
printf '%s: %s\n' "$ACTION" "${WT_REAL:-$RECEIPT}"
