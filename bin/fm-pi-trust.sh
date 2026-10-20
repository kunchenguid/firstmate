#!/usr/bin/env bash
# Pre-register Pi's own project trust for the isolated task worktree a
# pi/pi-signed spawn is about to launch a crewmate or scout into, so the worker
# reaches its brief instead of parking on the "Trust project folder?" dialog
# with nobody at the window to press Enter.
#
# Usage: fm-pi-trust.sh [--agent-dir <dir>] <worktree> <project>
#   --agent-dir <dir>  the Pi agent root the launch will read (its
#                      PI_CODING_AGENT_DIR); default $PI_CODING_AGENT_DIR, then
#                      $HOME/.pi/agent
#   <worktree>         the isolated task worktree this spawn launches into
#   <project>          the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Pi gates a directory it has never been told about behind
# "Trust project folder?" whenever that directory (or an ancestor) holds a
# trust-requiring resource, and a firstmate task worktree always does: its
# `.agents/skills` tree is one of them. The dialog is interactive, firstmate's
# steering plane carries no arrow navigation and must not answer an agent's
# dialog, so an unattended crewmate wedges there and produces nothing - the
# observed loss this control removes. Every fresh pooled slot therefore hits it
# once per slot, forever, because trust is remembered per path.
#
# THE TRUST RECORD IS PI'S OWN, NOT A NEW ONE. Verified against the installed Pi
# package (0.84.2) rather than from memory: `getAgentDir()` in
# `dist/config.js` resolves `PI_CODING_AGENT_DIR` when set and else
# `<homedir>/.pi/agent`; `dist/core/trust-manager.js` puts the store at
# `<agentDir>/trust.json`; the file is one JSON object keyed by the ABSOLUTE,
# realpath-resolved directory (`canonicalizePath(resolvePath(cwd))`, so symlinks
# are resolved and the logical path is never a key) with values `true`
# (trusted), `false` (declined), or `null` (recorded as undecided); a lookup
# walks the directory's ancestors and takes the nearest entry; writes are
# sorted-key, two-space pretty JSON with a trailing newline. `resolveProjectTrusted`
# in `dist/core/project-trust.js` reads that decision before it ever prompts, so
# an entry written ahead of launch means the worker starts straight into its
# turn. The exact keys and the live probe are recorded in the PR body and
# docs/verification/runtime-backends.md.
#
# An existing `true` for this exact path is success with NO write at all, which
# is what makes the registration idempotent across the relaunches and the pooled
# slot's later reuse. An existing `false` - a human's explicit "Do not trust"
# recorded for this path - is REFUSED rather than flipped: a spawn may not
# spend a decision the operator already made, and launching anyway would wedge
# exactly as before. Nothing else in the store is touched: no other entry is
# added, removed, or rewritten, and the parent directory, the project checkout,
# the home directory, and `/` are never registered - only the one absolute path
# this spawn actually uses.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-agy-trust.sh and
# bin/fm-claude-trust.sh: <worktree> must be a LINKED git worktree - its own git
# dir, sharing <project>'s common dir - whose top level is exactly the resolved
# argument. A primary checkout, a worktree of an unrelated repo, a subdirectory
# of a worktree, a plain directory, a home directory, and `/` are each refused
# with a non-zero exit, never a warning and never a silent skip. Only the
# launching user's own store is written, it must be a regular file this uid
# owns, every unrelated entry is preserved, and the replacement is atomic.
#
# FAILURE IS LOUD BY DESIGN. fm-spawn.sh treats a non-zero exit here as a spawn
# refusal, because continuing would launch a worker straight back into the
# dialog nobody can answer. A missing node, an unreadable or non-object store, a
# store that keeps moving under the read-modify-write, and a write whose entry
# does not read back all refuse with a message naming the store.
#
# Secondmate homes are deliberately out of scope. Their launch already carries
# Pi's session-scoped `--approve` for the home it starts in, so no persistent
# entry is needed there; registering one would widen a home-level grant for no
# gain.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect a relative `cd` operand, and the git overrides would make a primary
# checkout report a linked worktree's git dir, so the primary-checkout refusal
# would pass. Clear the whole class once here and every subshell inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-pi-trust.sh [--agent-dir <dir>] <worktree> <project>" >&2
  exit 2
}

AGENT_ARG=
case "${1:-}" in
--agent-dir)
  [ "$#" -eq 4 ] || usage
  AGENT_ARG=$2
  shift 2
  ;;
-h | --help)
  usage
  ;;
esac
[ "$#" -eq 2 ] || usage
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

[ -n "${HOME:-}" ] || refuse "HOME is not set, so Pi's agent root cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"

# The launch forwards a pinned agent root verbatim, so a relative value would
# name one directory here and another once the worker resolves it. Refuse rather
# than guess, the same way bin/fm-claude-trust.sh treats a relative
# CLAUDE_CONFIG_DIR.
AGENT_DIR=${AGENT_ARG:-${PI_CODING_AGENT_DIR:-$HOME_REAL/.pi/agent}}
case $AGENT_DIR in
'') refuse "the Pi agent root is empty, so the trust store cannot be located" ;;
/*) ;;
*) refuse "the Pi agent root '$AGENT_DIR' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
esac

[ "$WT_REAL" != / ] || refuse "'/' is the filesystem root, not a task worktree"
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

# The store write needs node, and a missing interpreter refuses like every other
# failure here: degrading would launch a worker straight into the dialog this
# registration exists to remove, which is the one outcome the whole control is
# for.
command -v node >/dev/null 2>&1 || refuse "node is required to record project trust and was not found on PATH"

# Pi creates this directory on its own first run, so create it here for the same
# reason: a root that cannot be written means the worker meets the dialog.
mkdir -p "$AGENT_DIR" 2>/dev/null || true
AGENT_DIR_REAL=$(real_dir "$AGENT_DIR") || true
[ -n "$AGENT_DIR_REAL" ] || refuse "Pi agent root '$AGENT_DIR' does not exist and could not be created"
[ "$WT_REAL" != "$AGENT_DIR_REAL" ] || refuse "'$WT_REAL' is the Pi agent root, not a task worktree"

STORE="$AGENT_DIR_REAL/trust.json"
# A dotfile manager or a synced folder legitimately symlinks this store, so the
# link is followed to its target and every check below judges that target.
# Writing to the resolved path keeps the link itself in place.
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
# after it, the bin/fm-agy-trust.sh shape: a live Pi session rewrites this same
# file when it settles a trust dialog, so a store that moved under us is retried
# once and then refused rather than clobbered. Losing a write the vendor made is
# the serious direction, because this re-serialises the whole file; losing ours
# only resurrects the dialog, which the readback catches inside these attempts.
# The vendor's own lock cannot be taken here without risking a live session's
# write, so the residual race is narrowed rather than closed and this claims no
# more than that.
if ! RESULT=$(node - "$STORE" "$WT_REAL" <<'NODE'
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
  if (root[target] === true) return "present";
  // A recorded decline is a human decision, not a missing entry. Refuse rather
  // than reverse it; the spawn stops and reports instead of launching a worker
  // that would wedge on the dialog anyway.
  if (root[target] === false) return "declined";
  for (const [key, value] of Object.entries(root)) {
    if (value !== true && value !== false && value !== null) {
      throw new Error(`${store} has a non-boolean value for ${JSON.stringify(key)}, so Pi would reject the whole store`);
    }
  }
  root[target] = true;
  const sorted = {};
  for (const key of Object.keys(root).sort()) sorted[key] = root[key];
  // Unpredictable name plus an exclusive create: the agent root may be writable
  // by another local account, and a predictable path could be pre-created there
  // as a symlink that a plain write would follow.
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
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return back[target] === true ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "present" || result === "recorded") {
      process.stdout.write(`${result}\n`);
      process.exit(0);
    }
    if (result === "declined") {
      console.error(`error: ${store} records "Do not trust" for ${target}; refusing to reverse the operator's recorded decision. Remove that entry or answer the dialog interactively once to recover`);
      process.exit(1);
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
console.error(`error: ${store} did not retain trust for ${target} after 3 attempts`);
process.exit(1);
NODE
); then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

if [ "$RESULT" = present ]; then
  echo "already trusted: $WT_REAL"
else
  echo "trusted: $WT_REAL"
fi
