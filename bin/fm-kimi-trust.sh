#!/usr/bin/env bash
# Pre-register Kimi Code's workspace trust for the isolated task worktree a
# ship/scout spawn is about to launch a kimi crewmate into, so the worker
# reaches its brief in the worktree instead of parking on the folder-trust
# dialog it cannot be steered past.
#
# Usage: fm-kimi-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Kimi Code 2.0.0 gates every folder it has not trusted behind
# "Trust this folder?" before it creates a session, and no launch flag
# suppresses it (`kimi --help` lists none; --auto is a permission tier, not a
# trust control). The dialog explains itself as "Project-level MCP servers are
# disabled until you explicitly choose Trust", but it renders whether or not
# the folder has any MCP configuration: the TUI's startup gate shows it
# whenever its trust lookup for process.cwd() comes back false. Every task
# worktree is a directory Kimi has never seen, so it fired on every spawn, and
# the brief pointer the spawn typed afterwards landed in front of a dialog
# rather than in a composer. Three consecutive dispatches were misread as
# pointer-delivery drops before an interrupt cleared the composer and revealed
# the dialog underneath. Registering the trust before launch removes the
# dialog; bin/fm-spawn.sh keeps its live answer as the backstop and refuses
# the launch when this registration fails, because a worker launched without
# it wedges before it reads anything.
#
# THE STORE, verified against the installed 2.0.0 bundle
# (packages/agent-core-v2/src/workspace/workspaceTrust/trustRecord.ts,
# _base/utils/workdir-slug.ts, _base/utils/paths.ts and
# persistence/backends/node-fs/atomicDocumentStore.ts) and against the records
# Kimi itself wrote on this machine:
#   - Directory: ${KIMI_CODE_HOME:-$HOME/.kimi-code}/workspace-trust/, mode
#     0700. Kimi resolves its home as KIMI_CODE_HOME first, then ~/.kimi-code.
#   - One regular file per trusted root, mode 0600, named
#     wd_<slug>_<hash>, where <slug> is the root's last path segment
#     lowercased, every run of characters outside [a-z0-9._-] collapsed to one
#     dash, leading and trailing dashes stripped, truncated to 40 characters and
#     stripped again ("workspace" when nothing is left), and <hash> is the first
#     12 lowercase hex characters of the SHA-256 of the root path with any
#     trailing slash removed and no trailing newline. /home/bemsas hashes to
#     495d3edf4d70 and its record is wd_bemsas_495d3edf4d70.
#   - Contents: JSON.stringify({root, trustedAt}) - one line, no trailing
#     newline, root the absolute path and trustedAt epoch milliseconds.
#   - The lookup is docs.get("workspace-trust", key) !== undefined, so a record
#     that exists and decodes as JSON is trust; the root field is informational.
#     A record that fails to decode is treated as untrusted and the dialog shows.
#
# TRUST IS PER EXACT ROOT AND IS NOT INHERITED. The lookup hashes the exact
# working directory; it never walks ancestors. /home/bemsas being trusted did
# nothing for a worktree beneath it, which is why every worktree needs its own
# record. The root Kimi hashes is the TUI's process.cwd(), which on Linux and
# macOS is the pane's physical path, so the resolved worktree path is the only
# root registered here: exactly one record per spawn, for the one key Kimi
# looks up. A worktree reached through a symlink is resolved first and gets
# that same single record.
#
# PRESERVATION IS STRUCTURAL. The store is one file per root, so this never
# reads, re-serialises, or renames over any record but the worktree's own:
# an existing record for this root that decodes as JSON is left untouched
# (idempotent success, its trustedAt intact), an absent one is created, and
# only a record Kimi itself would reject - one that does not decode - is
# replaced, because Kimi overwrites exactly that file when the dialog is
# answered. Each write lands as an exclusive-create temp file renamed over the
# record, mode 0600, then is read back before success is reported. A symlink in
# the record's place is refused rather than followed, since a link is a way to
# make some other file's bytes stand in for the record.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh:
# <worktree> must be a LINKED git worktree - its own git dir, sharing
# <project>'s common dir - whose top level is exactly the resolved argument. A
# primary checkout, a worktree of an unrelated repo, a subdirectory of a
# worktree, a plain directory, the home directory, the Kimi home, and the
# filesystem root are each refused with a non-zero exit, never a warning and
# never a silent skip. Only the launching user's own store is written and its
# directory must be one this uid owns.
#
# SECONDMATE HOMES ARE OUT OF SCOPE, AND THAT IS A GAP, NOT A PROOF. This
# helper covers crewmate and scout launches only: it has the worktree shape and
# nothing else, and bin/fm-spawn.sh calls it for those two kinds. A kimi
# SECONDMATE is a supported launch and its home is NOT pre-registered, so such a
# pane still meets the folder-trust dialog and still depends entirely on the
# live Enter in kimi_wait_for_ready - the backstop three consecutive dispatches
# showed firstmate cannot rely on. Closing that gap means a --secondmate-home
# mode like bin/fm-claude-trust.sh's, whose seed evidence proves the home is the
# one the spawn is about to launch into; it is not a widening of this scope
# test.
#
# KIMI_CODE_HOME. This honours it because Kimi does, but unlike CLAUDE_CONFIG_DIR
# bin/fm-spawn.sh does not forward it onto the launch: the pane's own shell
# must carry the same value for the worker to read the store written here, and
# the spawn's live backstop answers the dialog when it does not. A relative
# value is refused rather than guessed at, for the reason the claude helper
# gives: it would resolve against this process's cwd here and the pane's cwd
# there.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect a relative `cd` operand, and an inherited GIT_DIR with GIT_WORK_TREE
# makes a primary checkout report a linked worktree's git dir, so the
# primary-checkout refusal would pass. Clear the whole class once here so every
# subshell inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-kimi-trust.sh <worktree> <project>" >&2
  exit 2
}

case "${1:-}" in
  '' | -h | --help) usage ;;
esac
[ "$#" -eq 2 ] || usage
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register Kimi trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "task worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so Kimi's home directory cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"

case ${KIMI_CODE_HOME:-} in
  '') KIMI_HOME="$HOME_REAL/.kimi-code" ;;
  /*) KIMI_HOME=$KIMI_CODE_HOME ;;
  *) refuse "KIMI_CODE_HOME '$KIMI_CODE_HOME' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
esac

# The filesystem root, the home directory, and Kimi's own home are never
# something this registers. Checked explicitly so the refusal names the real
# reason instead of the scope verdict behind it.
[ "$WT_REAL" != / ] || refuse "'/' is the filesystem root, not a task worktree"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"
KIMI_HOME_REAL=$(real_dir "$KIMI_HOME") || true
if [ -n "$KIMI_HOME_REAL" ]; then
  [ "$WT_REAL" != "$KIMI_HOME_REAL" ] || refuse "'$WT_REAL' is the Kimi home directory, not a task worktree"
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

# The record write needs node, and a missing interpreter refuses like every
# other failure here: degrading would launch a worker straight into the dialog
# this registration exists to remove. Node is also what makes the key
# derivation byte-identical to Kimi's own, which runs the same JavaScript
# lowercasing and regular expression over the path.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

# Kimi creates its home with mode 0700 and the store directory with mode 0700
# (its file storage service is seeded with dirMode 448), so an absent one is
# created the same way; an existing one is left with whatever mode it has. A
# dotfile manager may symlink either directory, so the link is followed and
# the target judged. Ownership is the property that matters: another user's
# directory is refused however it is reached.
if [ ! -e "$KIMI_HOME" ]; then
  mkdir -m 0700 "$KIMI_HOME" 2>/dev/null || true
fi
KIMI_HOME_REAL=$(real_dir "$KIMI_HOME") || true
[ -n "$KIMI_HOME_REAL" ] || refuse "Kimi home '$KIMI_HOME' does not exist and could not be created"
[ -O "$KIMI_HOME_REAL" ] || refuse "Kimi home '$KIMI_HOME_REAL' is not owned by this user"
STORE_DIR="$KIMI_HOME_REAL/workspace-trust"
if [ ! -e "$STORE_DIR" ]; then
  mkdir -m 0700 "$STORE_DIR" 2>/dev/null || true
fi
[ -e "$STORE_DIR" ] || refuse "Kimi trust store '$STORE_DIR' does not exist and could not be created"
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] && [ -d "$STORE_DIR_REAL" ] \
  || refuse "'$STORE_DIR' is not a directory, so Kimi's trust store cannot be written"
[ -O "$STORE_DIR_REAL" ] || refuse "Kimi trust store '$STORE_DIR_REAL' is not owned by this user"
[ -w "$STORE_DIR_REAL" ] || refuse "Kimi trust store '$STORE_DIR_REAL' is not writable"

# Everything below the argument list is Kimi's own derivation, transcribed from
# the 2.0.0 bundle: canonicalWorkspaceRoot (path.resolve, trailing slashes
# stripped, lowercased only for Windows-shaped paths), slugifyWorkDirName and
# encodeWorkDirKey. It must not be "simplified" into shell: the slug lowercases
# and matches with JavaScript semantics over the same string Kimi sees.
if ! node - "$STORE_DIR_REAL" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [storeDir, wanted] = process.argv.slice(2);
const MAX_WORKDIR_SLUG_LENGTH = 40;
const WORKDIR_KEY_PREFIX = "wd_";
const HASH_LENGTH = 12;
const WIN_SHAPED = /^(?:[A-Za-z]:[\\/]|\\\\|\/\/)/;
const slugifyWorkDirName = (name) => {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, MAX_WORKDIR_SLUG_LENGTH)
    .replace(/^-+|-+$/g, "");
  return slug === "" || slug === "." || slug === ".." ? "workspace" : slug;
};
const encodeWorkDirKey = (workDir) => {
  const normalized = workDir.replace(/\\/g, "/").replace(/\/+$/, "");
  const last = normalized.split("/").pop() ?? normalized;
  const hash = crypto.createHash("sha256").update(normalized).digest("hex").slice(0, HASH_LENGTH);
  return `${WORKDIR_KEY_PREFIX}${slugifyWorkDirName(last)}_${hash}`;
};
const canonicalWorkspaceRoot = (cwd) => {
  const resolved = path.resolve(cwd);
  const slashed = resolved.replace(/\\/g, "/");
  const normalized = slashed.replace(/\/+$/, "");
  return (WIN_SHAPED.test(slashed) ? normalized.toLowerCase() : normalized) || resolved;
};
const decodes = (file) => {
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    return value !== null && typeof value === "object" && !Array.isArray(value);
  } catch {
    return false;
  }
};
const uid = process.getuid();
const root = canonicalWorkspaceRoot(wanted);
try {
  const file = path.join(storeDir, encodeWorkDirKey(root));
  let existing = null;
  try {
    existing = fs.lstatSync(file);
  } catch (err) {
    if (err.code !== "ENOENT") throw err;
  }
  let write = true;
  if (existing !== null) {
    if (existing.isSymbolicLink()) throw new Error(`${file} is a symlink; a Kimi trust record is a regular file`);
    if (!existing.isFile()) throw new Error(`${file} is not a regular file`);
    if (existing.uid !== uid) throw new Error(`${file} is not owned by this user`);
    // A record that decodes is trust already, however old: leave it and its
    // trustedAt alone. One that does not decode is what Kimi treats as
    // untrusted and overwrites on an answered dialog, so it is replaced.
    write = !decodes(file);
  }
  if (write) {
    // Exclusive create under an unpredictable name, mode 0600 forced after the
    // open so the umask cannot widen it, then an atomic rename over the record.
    const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
    const tmp = path.join(storeDir, `.${path.basename(file)}.fm-trust.${unique}`);
    fs.writeFileSync(tmp, JSON.stringify({ root, trustedAt: Date.now() }), { mode: 0o600, flag: "wx" });
    let renamed = false;
    try {
      fs.chmodSync(tmp, 0o600);
      fs.renameSync(tmp, file);
      renamed = true;
    } finally {
      if (!renamed) fs.rmSync(tmp, { force: true });
    }
    if (!decodes(file)) throw new Error(`${file} did not retain a readable trust record for ${root}`);
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE_DIR_REAL'"
fi

echo "trusted: $WT_REAL"
