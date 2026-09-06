#!/usr/bin/env bash
# Pre-register Antigravity CLI's workspace trust for the isolated task worktree a
# ship/scout spawn is about to launch an agy crewmate into, so the worker reaches
# its brief instead of wedging on the trust dialog.
#
# Usage: fm-agy-trust.sh <worktree> <project>
#        fm-agy-trust.sh --remove <worktree>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# Registration also prints one `added: <path>` line per spelling this run PUT in
# the store, and none for a spelling that was already there. That distinction is
# the caller's only way to tell its own registration from a workspace the
# operator trusted by hand, and withdrawing the latter would resurrect the very
# dialog this exists to remove. A run that adds nothing writes nothing.
#
# --remove retires a registration at teardown, so a vendor-owned settings file
# firstmate does not own cannot accumulate one dead absolute path per task (an
# orca task worktree is named for its task id, so every task is a new path).
# It takes no <project> and runs NO scope test, because the scope test is the
# safety property of GRANTING trust and removal can only ever withdraw it. It
# withdraws EXACTLY the spelling it is given - never the other spelling of the
# same directory, which may be the operator's own entry. It writes nothing when
# the named path is already absent, so calling it for a task that never ran on
# agy leaves the store untouched rather than rewritten, and an absent store is
# nothing to retire rather than a store to create.
#
# WHY THIS EXISTS. agy gates a folder it has never seen behind an interactive
# workspace-trust dialog, and --dangerously-skip-permissions does NOT cover it:
# that flag governs TOOL permissions only. Launching with it into a fresh
# worktree still renders "Do you trust the contents of this project?" with the
# cursor on "Yes, I trust this folder" and "No, exit" one row below. Every fresh
# task worktree therefore hits it. Firstmate's steering plane carries Enter,
# Escape and C-c with no arrow navigation, so firstmate cannot answer the dialog
# safely - and the dialog draws NO status-bar text at all, so a pane parked on it
# does not even render the `esc to cancel` a busy pane shows. The worker wedges
# before it ever reads the brief, looking like an idle pane. Registering the
# trust before launch is the only control that reaches an interactive pane.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a path
# policy. <worktree> must be a LINKED git worktree - its own git dir, sharing
# <project>'s common dir - whose top level is exactly the resolved argument. Git
# is the ground truth, so the argument is never trusted on its own word: a
# primary checkout (git dir == common dir), a worktree of an unrelated repo, a
# subdirectory of a worktree, a plain directory, and a home directory are each
# refused. Refusal is a non-zero exit, never a warning and never a silent skip.
#
# The test is deliberately NOT a treehouse or orca path prefix. Treehouse's root
# is configurable, so a prefix check would refuse legitimate roots, accept
# whatever a mutable env var names, and add exactly the policy surface this
# registration must not grow. One structural test covers both worktree providers
# because Orca's task worktree is a linked git worktree too.
#
# Only the launching user's own store is written: the trustedWorkspaces array in
# $HOME/.gemini/antigravity-cli/settings.json. Every unrelated key and every
# existing entry is preserved, and the replacement is atomic. That store location
# is resolved from HOME alone because agy exposes no config-directory override:
# JETSKI_APP_DATA_DIR, ANTIGRAVITY_EXECUTABLE_DATA_DIR and XDG_CONFIG_HOME were
# each set to an empty directory across an `agy models` run and none of them
# relocated a single file (agy 1.1.25). Recheck that if agy ever documents one,
# because a store the worker does not read is a registration that does nothing.
#
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect any relative `cd` operand - notably the `.git` that
# `git rev-parse --git-common-dir` returns for a primary checkout - into an
# unrelated directory. The git overrides do the same to git's own answers: an
# inherited GIT_DIR with GIT_WORK_TREE makes a primary checkout report a linked
# worktree's git dir, so the primary-checkout refusal would pass. Git exports
# GIT_DIR into every hook environment, so an inherited value is ordinary rather
# than hostile. Clear the whole class once here so every subshell inherits it and
# a later added git call cannot silently reintroduce the hole.
set -u

unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

MODE=register
if [ "${1-}" = --remove ]; then
  MODE=remove
  shift
  [ "$#" -eq 1 ] || { echo "usage: fm-agy-trust.sh --remove <worktree>" >&2; exit 2; }
  WT_ARG=$1
  PROJ_ARG=
else
  [ "$#" -eq 2 ] || { echo "usage: fm-agy-trust.sh <worktree> <project>" >&2; exit 2; }
  WT_ARG=$1
  PROJ_ARG=$2
fi

if [ "$MODE" = remove ]; then
  refuse() { echo "error: refusing to retire agy workspace trust: $1" >&2; exit 1; }
else
  refuse() { echo "error: refusing to pre-register agy workspace trust: $1" >&2; exit 1; }
fi

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The caller's own spelling of a directory, symlink components intact. agy runs
# in the pane's cwd, and Go's os.Getwd answers with $PWD when it names the same
# directory, so the trust lookup can present this spelling rather than the
# resolved one.
logical_dir() { (cd -- "$1" 2>/dev/null && pwd); }

# The fully resolved path of an existing file, or empty. Resolution runs in node
# because it must follow a symlink chain to its final target, and node is already
# this script's JSON writer.
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
if [ "$MODE" = register ]; then
  [ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
  PROJ_REAL=$(real_dir "$PROJ_ARG") || true
  [ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
fi

[ -n "${HOME:-}" ] || refuse "HOME is not set, so the agy settings store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
CONFIG_DIR="$HOME_REAL/.gemini/antigravity-cli"
# agy creates its own store directory on first run, so a home that has never run
# agy is ordinary rather than an error. Create the directory for the same reason,
# and refuse only when it genuinely cannot be written, since a store this cannot
# reach means the worker meets the dialog after all.
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
if [ -z "$CONFIG_DIR_REAL" ] && [ "$MODE" = register ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
fi
if [ "$MODE" = remove ]; then
  # A home that has never run agy holds no registration, so there is nothing to
  # retire and nothing to create on its behalf.
  [ -n "$CONFIG_DIR_REAL" ] || exit 0
  [ -e "$CONFIG_DIR_REAL/settings.json" ] || exit 0
else
  [ -n "$CONFIG_DIR_REAL" ] || refuse "agy settings directory '$CONFIG_DIR' does not exist and could not be created"

  # A home or config directory is never a task worktree. Checked explicitly so the
  # refusal names the real reason instead of the git verdict behind it.
  [ "$WT_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$WT_REAL' is the agy settings directory, not a task worktree"
  [ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

  WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
  WT_TOP_REAL=$(real_dir "$WT_TOP") || true
  [ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

  WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
  WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
  WT_COMMON=$(common_dir_of "$WT_REAL") || true
  [ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
  [ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

  PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
  [ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
  [ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

fi

# Every check above judges the resolved path, and that stays the scope boundary.
# REGISTRATION covers both spellings of that one directory, because a lookup miss
# is silent: agy parks on a dialog that draws no status text at all, and which
# spelling it presents depends on how its process was started.
#
# REMOVAL is deliberately NOT symmetric: it withdraws exactly the spelling it was
# named and never re-derives the pair. The caller withdraws from a record of the
# spellings its own registration reported ADDING, and the other spelling of the
# same directory may be an entry the operator made by hand - taking that one too
# would resurrect the very dialog this exists to remove. Withdrawing both is the
# caller naming both, once each.
if [ "$MODE" = remove ]; then
  case "$WT_ARG" in
    /*) WT_REAL=$WT_ARG ;;
    *) WT_REAL=$(logical_dir "$WT_ARG") || true ;;
  esac
  WT_LOGICAL=$WT_REAL
else
  WT_LOGICAL=$(logical_dir "$WT_ARG") || true
  [ -n "$WT_LOGICAL" ] && [ "$(real_dir "$WT_LOGICAL")" = "$WT_REAL" ] || WT_LOGICAL=$WT_REAL
fi
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' cannot be resolved to an absolute path"

# The store write needs node, and a missing interpreter refuses like every other
# failure here. Degrading instead would launch a worker straight into the dialog
# this registration exists to remove, which is the one outcome the whole control
# is for. A node-less home never reaches a spawn anyway, since bin/fm-bootstrap.sh
# lists node in COMMON_TOOLS and reports it at setup, which is where a missing
# tool belongs rather than as a stalled pane later.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

# Following the store symlink below is only safe while no other account can write
# the directory that holds it. Anyone who can create or replace an entry there
# repoints the store at an unrelated file THIS user owns, and every check on the
# store itself still passes, because the file that would be rewritten is owned by
# the very user this runs as - so ownership cannot catch it. Refusing a directory
# other accounts can write removes the ability to plant the link, rather than
# removing the symlink support a dotfile manager or synced folder legitimately
# needs. Reported by Greptile on kunchenguid/firstmate#3858.
#
# World-writable is unsafe everywhere. Group-writable is judged against the
# user's OWN primary group, because a private user group (the umask-002 default
# that leaves a home directory 0775 user:user) has no other members and refusing
# it would fail ordinary homes closed for no gain. A group that is NOT this
# user's primary group is a shared one and is refused.
# Known boundary: where the primary group is itself shared - macOS `staff` - a
# deliberately group-writable directory is not caught by this test. World-write
# and every foreign group are.
#
# node, not stat: `stat -c` is GNU-only and `stat -f` is BSD-only, and node is
# already required below as this script's JSON writer.
dir_writable_by_others() {  # <dir>
  node -e '
    const fs = require("node:fs");
    const st = fs.statSync(process.argv[1]);
    const worldWritable = (st.mode & 0o002) !== 0;
    const groupWritable = (st.mode & 0o020) !== 0;
    const foreignGroup = st.gid !== process.getgid();
    process.exit(worldWritable || (groupWritable && foreignGroup) ? 0 : 1);
  ' "$1" 2>/dev/null
}

refuse_loose_dir() {  # <dir> <label>
  ! dir_writable_by_others "$1" || refuse \
    "$2 '$1' is writable by other users, so the settings path it holds cannot be trusted; remove write access for others with: chmod go-w '$1'"
}

refuse_loose_dir "$CONFIG_DIR_REAL" "agy settings directory"

STORE="$CONFIG_DIR_REAL/settings.json"
# A dotfile manager or a synced folder legitimately symlinks this store, so the
# link is followed to its final target and every check below judges that target.
# Ownership is the property that matters: another user's file is refused however
# it is reached. Writing to the resolved path is what keeps the link itself in
# place, since staging beside the link and renaming would replace it with a
# regular file and break that layout.
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
  refuse_loose_dir "$(dirname "$STORE")" "the directory holding the resolved agy settings store"
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm. fm-spawn can run while an agy
# session of the operator's own writes this same file, so the store can move
# under us in both directions and each needs its own answer.
#
# Losing the VENDOR's write is the serious one: this renames a whole
# re-serialisation over the file, so anything agy changed since the read - a
# telemetry choice, another workspace's trust - would be gone, in a format this
# does not own. So the bytes read are fingerprinted and re-checked immediately
# before the rename, and a store that moved is not overwritten: the whole
# read-modify-write is retried once, and a second move refuses rather than
# clobbering.
#
# That narrows the window; it does not close it. Rename cannot be conditioned on
# content, so a write landing between the final check and the rename is still
# lost, and this claims no more than that.
#
# Losing OUR entry is the mild one: a vendor rewrite that drops it only
# resurrects the dialog this registration removes, which reaches firstmate as an
# ordinary stale wake and a relaunch registers again. The readback catches it
# within these attempts, and it must fail loudly rather than report a trust it
# did not leave.
# ponytail: fingerprint-and-refuse, not a lock; flock is absent on macOS and
# cannot stop a vendor session's own rewrite anyway.
if ! node - "$STORE" "$MODE" "$WT_REAL" "$WT_LOGICAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, mode, ...requested] = process.argv.slice(2);
// One directory, both spellings; a repeat spawn must not grow the array either.
const worktrees = [...new Set(requested.filter((value) => value !== ""))];
// The spellings this run actually PUT in the store, which is not the same as the
// spellings it was asked for: the operator may have trusted one of them by hand
// already. Only what this run added is this task's to withdraw later.
let added = [];
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
const attempt = () => {
  added = [];
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
  if (root.trustedWorkspaces === undefined) root.trustedWorkspaces = [];
  const trusted = root.trustedWorkspaces;
  if (!Array.isArray(trusted)) {
    throw new Error(`${store} has a non-array "trustedWorkspaces" value`);
  }
  if (mode === "remove") {
    const kept = trusted.filter((value) => !worktrees.includes(value));
    // Nothing of ours to withdraw is not a write: a task that never ran on agy
    // must not reformat the operator's settings file on its way out.
    if (kept.length === trusted.length) return "recorded";
    root.trustedWorkspaces = kept;
  } else {
    for (const worktree of worktrees) {
      if (trusted.includes(worktree)) continue;
      trusted.push(worktree);
      added.push(worktree);
    }
    // Already trusted is not a write either, for the same reason: re-serialising
    // the operator's settings file on every relaunch is a change they did not ask
    // for, and there is nothing to verify when nothing moved.
    if (added.length === 0) return "recorded";
  }
  // Two-space pretty-printed with a trailing newline, because that is the format
  // agy itself writes: the store measured on the box this was written on is
  // exactly `{\n  "enableTelemetry": ...\n}\n`. Compact would reformat the
  // operator's whole settings file on every spawn and agy's next write would
  // expand it again, so this must not be "simplified" to JSON.stringify(root).
  const body = `${JSON.stringify(root, null, 2)}\n`;
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.settings.json.fm-trust.${unique}`);
  fs.writeFileSync(tmp, body, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  const recorded = Array.isArray(back.trustedWorkspaces)
    ? (mode === "remove"
      ? worktrees.every((worktree) => !back.trustedWorkspaces.includes(worktree))
      : worktrees.every((worktree) => back.trustedWorkspaces.includes(worktree)))
    : false;
  return recorded ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") {
      for (const worktree of added) console.log(`added: ${worktree}`);
      process.exit(0);
    }
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(
  mode === "remove"
    ? `error: ${store} still trusts ${worktrees.join(", ")} after 3 attempts`
    : `error: ${store} did not retain trust for ${worktrees.join(", ")} after 3 attempts`,
);
process.exit(1);
NODE
then
  if [ "$MODE" = remove ]; then
    refuse "could not withdraw trust for '$WT_REAL' in '$STORE'"
  fi
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

if [ "$MODE" = remove ]; then
  echo "untrusted: $WT_REAL"
else
  echo "trusted: $WT_REAL"
fi
