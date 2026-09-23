#!/usr/bin/env bash
# Pre-register Kimi Code's workspace trust for the directory a kimi spawn is
# about to launch into - the isolated task worktree of a ship or scout crewmate,
# or the seeded home of a secondmate - so the worker reaches its brief or charter
# instead of opening on the full-screen folder-trust dialog.
#
# Usage: fm-kimi-trust.sh <worktree> <project>
#        fm-kimi-trust.sh --secondmate-home <home> <id>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   <home>      the seeded secondmate home this spawn launches into
#   <id>        the secondmate id that home must already be marked for
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Kimi Code gates a folder it has never seen behind a
# full-screen "Trust this folder?" dialog and no launch flag suppresses it
# (`kimi --help` on 2.0.2 lists none; --auto selects a permission tier, not
# folder trust). Every fresh task worktree therefore meets it before the brief
# is read. bin/fm-spawn.sh keeps a post-launch gate as the backstop - Kimi's
# dialog preselects the affirmative "Trust this folder", so the gate can answer
# it - but that gate depends on reading a vendor-rendered TUI frame through the
# backend's viewport capture, which is the fragile half: when the frame cannot be
# read the readiness wait times out, the spawn records a failure, and the pane is
# left behind. Registering the trust before launch removes the dialog outright so
# that path is never exercised. A failed registration here is therefore NOT fatal
# in the spawn - it warns and lets the live gate answer the dialog, the
# bin/fm-agy-trust.sh precedent for a harness whose dialog preselects the safe
# answer - and this script still refuses loudly so the warning names a cause.
#
# THE STORE IS ONE FILE PER WORKSPACE, WHICH IS WHY THIS IS SMALL. Kimi records
# trust as <home>/workspace-trust/<workspace-id>, a standalone JSON file
# {"root":"<absolute path>","trustedAt":<epoch ms>} written 0600 inside a 0700
# directory. Nothing else in that store is touched, so unlike
# bin/fm-claude-trust.sh's single shared .claude.json there is no
# read-modify-write over a document the vendor also rewrites, and no fingerprint
# retry is needed: one exclusive create of one new file either lands or does not.
#
# THE LOOKUP KEY IS THE FILENAME, NOT THE FILE'S CONTENT. Established on the
# installed Kimi Code 2.0.2 (docs/verification/kimi.md owns the commands and
# output): a trust file whose own "root" field names an unrelated directory
# still suppresses the dialog for the folder its FILENAME encodes, and a trust
# file carrying the correct "root" under any other filename does not. So the
# workspace-id derivation below is the load-bearing part, and the "root" field is
# written faithfully for the operator reading the store and for any future
# version that starts validating it, never relied on here.
#
# THE WORKSPACE ID is "wd_" + a slug of the resolved directory's basename + "_" +
# the first 12 hex characters of the sha256 of the resolved absolute path with no
# trailing slash. The slug lowercases, replaces each run of characters outside
# [a-z0-9._-] with a single "-", strips leading "-", truncates to 40 characters,
# then strips trailing "-", and falls back to "workspace" when nothing is left.
# Each of those steps is separately observed rather than assumed, including the
# order: leading strip happens BEFORE the 40-character truncation and trailing
# strip AFTER it, so a basename of five dashes then forty "b"s slugs to forty
# "b"s while one of thirty-nine "a"s, a dash, then "bbbb" slugs to thirty-nine
# "a"s. The rule reproduces all 81 workspace ids across the five Kimi homes on
# the box it was written on plus every deliberately awkward probe basename
# (uppercase, runs of spaces, accented characters, a leading dot, leading and
# trailing dashes, an all-punctuation name, a 132-character name).
#
# TRUST IS EXACT-DIRECTORY, WITH NO ANCESTOR WALK, so only the directory the pane
# starts in is registered. Verified by trusting a parent and launching in its
# child, which still showed the dialog. That is why worktree mode registers the
# worktree ALONE and never the primary checkout: the <project> argument is here
# only for the structural scope test below, and writing it would touch the
# captain's own interactive store for a directory this launch never enters.
# Kimi also RESOLVES the launch directory before deriving the id - a launch
# through a symlinked path recorded the physical path's id - so every path here
# is resolved first, and the logical form is deliberately not registered (the
# opposite of bin/fm-agy-trust.sh, whose harness compares the logical path).
#
# AN EXISTING RECORD IS NEVER OVERWRITTEN. Presence alone grants trust, so a
# folder the captain already trusted needs nothing and its original trustedAt
# timestamp is left intact; this reports it and succeeds.
#
# WHICH HOME. $HOME/.kimi-code, the same home bin/fm-kimi-turnend-hook.sh
# installs the crew turn-end region into and the same one bin/fm-spawn.sh's
# per-task token registry lives under. It must ALREADY EXIST: Kimi creates it on
# its own first run, and a home this would have to create is one Kimi has never
# initialised, holding neither credentials nor config, where a trust record buys
# the worker nothing. An absent home is therefore refused rather than
# provisioned, and bin/fm-spawn.sh turns that refusal into its warning so the
# live dialog gate answers. Multi-home support (KIMI_CODE_HOME) is deliberately
# out of scope: it is only correct if trust, the turn-end hook, the hook script
# and the token registry move to the selected home together, and moving only
# this one puts the record in a home whose config.toml carries no Firstmate
# hook.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a path
# policy. Both modes mirror bin/fm-claude-trust.sh, which owns the full reasoning
# for each shape; only the differences that matter here are restated.
#
# WORKTREE MODE. <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument. A primary checkout, a worktree of an unrelated repo, a subdirectory
# of a worktree, a plain directory, and a home directory are each refused with a
# non-zero exit, never a warning and never a silent skip.
#
# SECONDMATE-HOME MODE. Kimi is a verified secondmate harness, and a secondmate
# home is a whole firstmate instance rather than a task worktree, so the worktree
# test cannot decide it. THE SEED IS the evidence: the home must carry a
# .fm-secondmate-home marker that is a regular file this user owns, never a
# symlink, naming exactly the <id> passed; it must hold the firstmate instance
# files AGENTS.md and bin/; and each of its data, state, config and projects
# paths must resolve inside the home.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect any relative `cd` operand, and an inherited GIT_DIR with GIT_WORK_TREE
# makes a primary checkout report a linked worktree's git dir, so the
# primary-checkout refusal would pass. Git exports GIT_DIR into every hook
# environment, so an inherited value is ordinary rather than hostile.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-kimi-trust.sh <worktree> <project>" >&2
  echo "       fm-kimi-trust.sh --secondmate-home <home> <id>" >&2
  exit 2
}

case "${1:-}" in
--secondmate-home)
  [ "$#" -eq 3 ] || usage
  MODE=secondmate-home
  TARGET_ARG=$2
  SUB_ID=$3
  PROJ_ARG=
  SCOPE_NOUN="secondmate home"
  ;;
'' | -h | --help)
  usage
  ;;
*)
  [ "$#" -eq 2 ] || usage
  MODE=worktree
  TARGET_ARG=$1
  SUB_ID=
  PROJ_ARG=$2
  SCOPE_NOUN="task worktree"
  ;;
esac

refuse() {
  echo "error: refusing to pre-register Kimi trust: $1" >&2
  exit 1
}

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

TARGET_REAL=$(real_dir "$TARGET_ARG") || true
[ -n "$TARGET_REAL" ] || refuse "$SCOPE_NOUN '$TARGET_ARG' is not an accessible directory"
if [ "$MODE" = worktree ]; then
  PROJ_REAL=$(real_dir "$PROJ_ARG") || true
  [ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
fi

[ -n "${HOME:-}" ] || refuse "HOME is not set, so the Kimi home cannot be located"
KIMI_HOME="$HOME/.kimi-code"
KIMI_HOME_REAL=$(real_dir "$KIMI_HOME") || true
[ -n "$KIMI_HOME_REAL" ] || refuse "Kimi home '$KIMI_HOME' is not an accessible directory; Kimi creates it on its first run, and this registers trust only in a home Kimi has already initialised"

# The filesystem root, a home directory, and the Kimi home itself are never
# something this registers. Checked explicitly so the refusal names the real
# reason instead of the scope verdict behind it.
[ "$TARGET_REAL" != / ] || refuse "'/' is the filesystem root, not a $SCOPE_NOUN"
[ "$TARGET_REAL" != "$KIMI_HOME_REAL" ] || refuse "'$TARGET_REAL' is the Kimi home directory, not a $SCOPE_NOUN"
HOME_REAL=$(real_dir "$HOME") || true
[ "$TARGET_REAL" != "${HOME_REAL:-}" ] || refuse "'$TARGET_REAL' is the home directory, not a $SCOPE_NOUN"

if [ "$MODE" = worktree ]; then
  WT_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$WT_TOP" ] || refuse "'$TARGET_REAL' is not inside a git repository"
  WT_TOP_REAL=$(real_dir "$WT_TOP") || true
  [ "$WT_TOP_REAL" = "$TARGET_REAL" ] || refuse "'$TARGET_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

  WT_GIT_DIR=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has no resolvable git directory"
  WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has an unresolvable git directory"
  WT_COMMON=$(common_dir_of "$TARGET_REAL") || true
  [ -n "$WT_COMMON" ] || refuse "'$TARGET_REAL' has no resolvable git common directory"
  [ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$TARGET_REAL' is a primary checkout, not an isolated worktree"

  PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
  [ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
  [ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$TARGET_REAL' is not a worktree of project '$PROJ_REAL'"
else
  # The seed evidence, in the order that names the most useful reason first. The
  # marker is the token the whole boundary rests on, so it is judged as a file
  # rather than as a value: a symlink is refused outright rather than followed,
  # because a link is a way to make some other file's bytes stand in for the
  # seed, and a marker this user does not own was planted by someone else.
  [ -n "$SUB_ID" ] || refuse "no secondmate id was supplied, so '$TARGET_REAL' cannot be matched against its seed marker"
  SUB_MARKER="$TARGET_REAL/.fm-secondmate-home"
  [ ! -L "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is a symlink; a seeded secondmate home carries the marker as a regular file"
  [ -f "$SUB_MARKER" ] || refuse "'$TARGET_REAL' carries no .fm-secondmate-home marker, so it is not a seeded secondmate home"
  [ -O "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is not owned by this user"
  SUB_MARKER_ID=$(cat "$SUB_MARKER" 2>/dev/null) || true
  [ "$SUB_MARKER_ID" = "$SUB_ID" ] || refuse "'$TARGET_REAL' is marked for secondmate '${SUB_MARKER_ID:-unknown}', not '$SUB_ID'"
  [ -f "$TARGET_REAL/AGENTS.md" ] || refuse "'$TARGET_REAL' has no AGENTS.md, so it is not a firstmate home"
  [ -d "$TARGET_REAL/bin" ] || refuse "'$TARGET_REAL' has no bin/, so it is not a firstmate home"
  for sub_dir_name in data state config projects; do
    sub_dir="$TARGET_REAL/$sub_dir_name"
    if [ -L "$sub_dir" ] && [ ! -e "$sub_dir" ]; then
      refuse "'$sub_dir' is a broken symlink, so this home's $sub_dir_name directory cannot be shown to stay inside it"
    fi
    [ -e "$sub_dir" ] || continue
    [ -d "$sub_dir" ] || refuse "'$sub_dir' is not a directory, so '$TARGET_REAL' is not a seeded secondmate home"
    sub_dir_real=$(real_dir "$sub_dir") || true
    [ -n "$sub_dir_real" ] || refuse "'$sub_dir' cannot be resolved"
    case "$sub_dir_real" in
    "$TARGET_REAL"/*) ;;
    *) refuse "'$sub_dir' resolves to '$sub_dir_real', outside the home, so '$TARGET_REAL' is not a safe secondmate home" ;;
    esac
  done
fi

# The id derivation and the store write need node, and a missing interpreter
# refuses like every other failure here. bin/fm-spawn.sh turns that refusal into
# a warning and lets the live dialog gate answer the dialog instead, so a
# node-less box still spawns; bin/fm-bootstrap.sh lists node in COMMON_TOOLS and
# reports it at setup, which is where a missing tool belongs.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

TRUST_DIR="$KIMI_HOME_REAL/workspace-trust"
if [ -e "$TRUST_DIR" ] || [ -L "$TRUST_DIR" ]; then
  [ ! -L "$TRUST_DIR" ] || refuse "'$TRUST_DIR' is a symlink; Kimi keeps its workspace-trust store as a real directory"
  [ -d "$TRUST_DIR" ] || refuse "'$TRUST_DIR' exists but is not a directory, so the Kimi trust store is malformed"
  [ -O "$TRUST_DIR" ] || refuse "'$TRUST_DIR' is not owned by this user"
  [ -w "$TRUST_DIR" ] || refuse "'$TRUST_DIR' is not writable"
else
  # 0700 is the mode Kimi itself creates this directory with, and it is set at
  # creation rather than chmod'd afterwards so the store is never briefly
  # group- or world-readable. The Kimi home above is already resolved, so this
  # is a single-level create and needs no -p (which would apply the mode to the
  # deepest component only).
  mkdir -m 700 "$TRUST_DIR" 2>/dev/null || true
  [ -d "$TRUST_DIR" ] || refuse "Kimi trust store '$TRUST_DIR' does not exist and could not be created"
fi

if ! node - "$TRUST_DIR" "$TARGET_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [trustDir, target] = process.argv.slice(2);
// Kimi's own derivation, step for step and in its observed order: the leading
// strip runs before the 40-character truncation and the trailing strip after it.
// See this script's header for the evidence behind each step.
const slug = (basename) => {
  const s = basename
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+/, "")
    .slice(0, 40)
    .replace(/-+$/, "");
  return s === "" ? "workspace" : s;
};
const workspaceId = (root) =>
  `wd_${slug(path.basename(root))}_${crypto.createHash("sha256").update(root).digest("hex").slice(0, 12)}`;
const register = () => {
  const id = workspaceId(target);
  const record = path.join(trustDir, id);
  // Presence alone grants trust, so an existing record is left exactly as it is -
  // including a trustedAt the captain's own session wrote. A symlink here is not
  // a record this may treat as trust: it makes some other file's bytes stand in
  // for the store's own, so it refuses rather than reporting a trust it did not
  // verify.
  let existing = null;
  try {
    existing = fs.lstatSync(record);
  } catch (err) {
    if (err.code !== "ENOENT") throw err;
  }
  if (existing !== null) {
    if (existing.isSymbolicLink()) {
      throw new Error(`${record} is a symlink, not a Kimi trust record`);
    }
    if (!existing.isFile()) {
      throw new Error(`${record} exists but is not a regular file, so the Kimi trust store is malformed`);
    }
    process.stdout.write(`already trusted: ${target} (${id})\n`);
    return;
  }
  // Unpredictable name plus an exclusive create: the home may be writable by
  // another local account, and a predictable path could be pre-created there as
  // a symlink that a plain write would follow into some other file this user
  // owns. "wx" refuses an existing path outright. The rename is within one
  // directory, so the record appears whole or not at all - Kimi never reads a
  // partial file.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(trustDir, `.fm-kimi-trust.${unique}`);
  // The field order and compact serialization Kimi itself writes, so an operator
  // reading the store cannot tell this record from one the vendor wrote.
  const body = JSON.stringify({ root: target, trustedAt: Date.now() });
  fs.writeFileSync(tmp, body, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    fs.renameSync(tmp, record);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  // Read back rather than trusting the write: a registration that did not land
  // must fail loudly instead of reporting a trust the worker will not see.
  const back = JSON.parse(fs.readFileSync(record, "utf8"));
  if (back.root !== target) {
    throw new Error(`${record} did not retain root ${target} after writing it`);
  }
  process.stdout.write(`trusted: ${target} (${id})\n`);
};
try {
  register();
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
NODE
then
  refuse "could not record trust for '$TARGET_REAL' in '$TRUST_DIR'"
fi
