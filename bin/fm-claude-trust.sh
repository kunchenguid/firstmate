#!/usr/bin/env bash
# Pre-register Claude Code's workspace trust for the directory a claude spawn is
# about to launch into - the isolated task worktree of a ship or scout crewmate,
# or the seeded home of a secondmate - so the agent reaches its brief or charter
# instead of wedging on the trust dialog.
#
# Usage: fm-claude-trust.sh <worktree> <project>
#        fm-claude-trust.sh --secondmate-home <home> <id>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   <home>      the seeded secondmate home this spawn launches into
#   <id>        the secondmate id that home must already be marked for
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Claude Code gates a folder it has never seen behind an
# interactive workspace-trust dialog, and --dangerously-skip-permissions does
# NOT cover it: `claude --help` records that the dialog is skipped only in
# non-interactive mode (-p, or a non-TTY stdout), and a spawned pane is
# interactive. Every fresh task worktree therefore hits it, and so does every
# secondmate home the operator has not opened by hand. The dialog renders
# with the cursor on "No, exit" and firstmate's steering plane carries only
# Enter, Escape and C-c with no arrow navigation, so firstmate cannot answer it
# and must not try - pressing Enter would select exit. The agent wedges before
# it ever reads the brief. Registering the trust before launch is the only
# control that reaches an interactive pane.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy. Each mode has its own, because the two directories have entirely
# different shapes on disk.
#
# WORKTREE MODE. <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument. Git is the ground truth, so the argument is never trusted on its
# own word: a primary checkout (git dir == common dir), a worktree of an
# unrelated repo, a subdirectory of a worktree, a plain directory, and a home
# directory are each refused. Refusal is a non-zero exit, never a warning and
# never a silent skip.
#
# The test is deliberately NOT a treehouse or orca path prefix. Treehouse's
# root is configurable (--root, TREEHOUSE_ROOT, config, and a relative
# in-project pool), so a prefix check would refuse legitimate roots, accept
# whatever a mutable env var names, and add exactly the policy surface this
# registration must not grow. The structural test is verified for treehouse
# worktrees, which are linked git worktrees. Orca's worktree shape is UNVERIFIED:
# docs/orca-backend.md calls it an "independent worktree", which does not
# establish a shared git common dir, and orca is macOS-only and was not installed
# where this was written. If Orca clones instead of linking, its git dir equals
# its common dir, so this refuses it as a primary checkout and an orca claude
# spawn fails loudly here rather than wedging on the dialog later. fm-spawn.sh's
# own validate_spawn_worktree would not catch that case first: it compares the
# worktree root against the primary and never compares common dirs, so an
# independent clone passes it. Close this on a box that has Orca through the live
# opt-in guard family (FM_*_LIVE_E2E=1) and record the result in
# docs/verification/runtime-backends.md, rather than assuming the shape here.
#
# SECONDMATE-HOME MODE. A secondmate home is a whole firstmate instance rather
# than a task worktree, and bin/fm-home-seed.sh produces it in two shapes: a
# leased treehouse worktree (linked) and a standalone clone of the firstmate
# repo (a primary checkout). The worktree test above therefore cannot decide
# this case at all - it refuses the standalone clone as a primary checkout,
# which is why a claude secondmate in an explicit ~/fm-homes/<id> home met the
# dialog with nothing registered. Git shape is not the evidence here; THE SEED
# IS. The home must carry a .fm-secondmate-home marker that is a regular file
# this user owns, never a symlink, naming exactly the <id> passed; it must hold
# the firstmate instance files AGENTS.md and bin/; and each of its data, state,
# config and projects paths must resolve inside the home. That is the set
# bin/fm-home-seed.sh writes and bin/fm-spawn.sh's validate_firstmate_home_for_spawn
# re-checks before launch, so this accepts exactly the homes a secondmate spawn
# will launch into and nothing wider: a plain directory, a project checkout, an
# ordinary firstmate checkout, a home marked for a different secondmate, and a
# home whose operational directory escapes it are each refused. An ABSENT
# operational directory is accepted for the same reason the spawn accepts one -
# a test stricter than the spawn's own would move the wedge from the dialog to
# a refusal without making any unseeded directory less trusted.
#
# Home-level trust is broader than worktree trust, since the pane starts in the
# home and the secondmate works across it, so it is granted on that seed
# evidence alone and never on a caller's word about what a path is.
#
# Only the launching user's own store is written: the projects entry for the
# registered path in ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json, which must be a
# regular file this uid owns. Every unrelated key and project entry is
# preserved, and the replacement is atomic. fm-spawn.sh forwards CLAUDE_CONFIG_DIR
# onto the claude launch verbatim rather than resolving it, and the pane starts
# in the registered directory, so only an absolute value names the same store on
# both sides; a relative one is refused below rather than guessed at.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect any relative `cd` operand - notably the `.git` that
# `git rev-parse --git-common-dir` returns for a primary checkout - into an
# unrelated directory. The git overrides do the same to git's own answers: an
# inherited GIT_DIR with GIT_WORK_TREE makes a primary checkout report a linked
# worktree's git dir, so the primary-checkout refusal would pass. Git exports
# GIT_DIR into every hook environment, so an inherited value is ordinary rather
# than hostile. Clear the whole class once here so every subshell inherits it
# and a later added git call cannot silently reintroduce the hole.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-claude-trust.sh <worktree> <project>" >&2
  echo "       fm-claude-trust.sh --secondmate-home <home> <id>" >&2
  exit 2
}

# MODE selects which structural scope test decides the argument, and SCOPE_NOUN
# names what the argument was expected to be so every shared refusal below reads
# correctly in both modes.
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

refuse() { echo "error: refusing to pre-register Claude trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The fully resolved path of an existing file, or empty. Resolution runs in node
# because it must follow a symlink chain to its final target, and node is
# already this script's JSON writer.
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

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

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-}}
[ -n "$CONFIG_DIR" ] || refuse "neither CLAUDE_CONFIG_DIR nor HOME is set, so the store cannot be located"
# A relative value resolves against this process's cwd here but against the
# worker's own cwd once fm-spawn.sh forwards it verbatim onto the launch, so the
# two sides can name different stores and the registration would report a
# success the worker never sees. Refuse rather than guess at the worker's cwd.
case ${CLAUDE_CONFIG_DIR:-} in
  '' | /*) ;;
  *) refuse "CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
esac
# fm-spawn forwards a set CLAUDE_CONFIG_DIR onto the launch without requiring it
# to exist, because claude creates its own store directory. Create it here for
# the same reason, and refuse only when it genuinely cannot be written, since a
# store this cannot reach means the worker meets the dialog after all.
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
if [ -z "$CONFIG_DIR_REAL" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
fi
[ -n "$CONFIG_DIR_REAL" ] || refuse "Claude config directory '$CONFIG_DIR' does not exist and could not be created"

# The filesystem root, a home directory, and the config directory are never
# something this registers, in either mode. Checked explicitly so the refusal
# names the real reason instead of the scope verdict behind it.
[ "$TARGET_REAL" != / ] || refuse "'/' is the filesystem root, not a $SCOPE_NOUN"
[ "$TARGET_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$TARGET_REAL' is the Claude config directory, not a $SCOPE_NOUN"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$TARGET_REAL" != "${HOME_REAL:-}" ] || refuse "'$TARGET_REAL' is the home directory, not a $SCOPE_NOUN"
fi

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
  # The seed evidence, in the order that names the most useful reason first: the
  # marker decides whether this is a secondmate home at all, the id decides
  # whose, and the instance files and operational directories decide whether it
  # is the shape bin/fm-home-seed.sh leaves behind. The marker is the token the
  # whole boundary rests on, so it is judged as a file rather than as a value: a
  # symlink is refused outright rather than followed, because a link is a way to
  # make some other file's bytes stand in for the seed, and a marker this user
  # does not own was planted by someone else.
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

# The store write needs node, and a missing interpreter refuses like every other
# failure here. Degrading instead would launch a worker straight into the dialog
# this registration exists to remove, which is the one outcome the whole control
# is for; the other node callers in bin/ step aside because what they protect is
# optional, and this is not. A node-less home never reaches a spawn anyway, since
# bin/fm-bootstrap.sh lists node in COMMON_TOOLS and reports it at setup, which is
# where a missing tool belongs rather than as a stalled pane later.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"
# Presence is not health: a node that resolves on PATH and aborts on every
# invocation passes the check above and then fails real_file()'s node -e, so the
# spawn dies at bin/fm-spawn.sh's trust-registration step with no mention of node.
# Setup-time reporting does not cover this either, because bin/fm-bootstrap.sh
# tests COMMON_TOOLS with command -v as well. Executing the interpreter is the
# only check that distinguishes a broken one from a working one, and it is named
# separately from the missing case because the two have different remedies.
# The probe runs in a subshell that exits with node's status so that when node
# dies by signal, bash's own "Abort trap" job report lands on the subshell's
# redirected stderr and the operator sees only the named refusal below.
( node -e ''; exit $? ) >/dev/null 2>&1 || refuse "node is on PATH but failed to execute, so workspace trust cannot be recorded; check the interpreter itself with: node --version"

STORE="$CONFIG_DIR_REAL/.claude.json"
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
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm. fm-spawn runs from a live
# firstmate Claude Code session that writes this same file, so the store can move
# under us in both directions and each needs its own answer.
#
# Losing the VENDOR's write is the serious one: this renames a whole
# re-serialisation over the file, so anything Claude changed since the read -
# oauthAccount, user-scope mcpServers, another project's history - would be gone,
# in a format this does not own. So the bytes read are fingerprinted and
# re-checked immediately before the rename, and a store that moved is not
# overwritten: the whole read-modify-write is retried once, and a second move
# refuses rather than clobbering.
#
# That narrows the window; it does not close it. Rename cannot be conditioned on
# content, so a write landing between the final check and the rename is still
# lost, and this claims no more than that.
#
# Losing OUR entry is the mild one: a vendor rewrite that drops it only resurrects
# the dialog this registration removes, which reaches firstmate as an ordinary
# stale wake and a relaunch registers again. The readback catches it within these
# attempts, and it must fail loudly rather than report a trust it did not leave.
# ponytail: fingerprint-and-refuse, not a lock; flock is absent on macOS and
# cannot stop a vendor session's own rewrite anyway.
if ! node - "$STORE" "$TARGET_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, target] = process.argv.slice(2);
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
  if (root.projects === undefined) root.projects = {};
  const projects = root.projects;
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    throw new Error(`${store} has a non-object "projects" value`);
  }
  let entry = projects[target];
  if (entry === undefined || entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    entry = {};
  }
  entry.hasTrustDialogAccepted = true;
  projects[target] = entry;
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${unique}`);
  // Two-space pretty-printed, because that is the format Claude Code itself
  // writes: the store on the box this was measured on begins "{\n  " and runs
  // 9646 lines. Compact would reformat the operator's whole config on every
  // spawn and the vendor's next write would expand it again, so this must not
  // be "simplified" to JSON.stringify(root) without re-measuring the vendor.
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return back.projects?.[target]?.hasTrustDialogAccepted === true ? "recorded" : "dropped";
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
console.error(`error: ${store} did not retain trust for ${target} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$TARGET_REAL' in '$STORE'"
fi

echo "trusted: $TARGET_REAL"
