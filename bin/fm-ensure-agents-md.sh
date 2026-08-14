#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md points at
# it for compatibility, as a relative symlink when this worktree's git will
# actually materialize one, or as a real regular-file duplicate kept in sync
# otherwise (see claude_symlink_unsafe() below). A duplicate CLAUDE.md carries
# a trailing sync marker so a later run can resync it after AGENTS.md alone
# changes instead of hard-refusing a mismatch it caused itself (see
# claude_has_marker() below). Creates a minimal AGENTS.md skeleton when
# neither file exists, promotes a real CLAUDE.md file when it is the only
# file present, and refuses to clobber distinct real files or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, injecting it idempotently into created skeletons,
# promoted CLAUDE.md files, and any existing AGENTS.md that still lacks it.
# Refuses a case-variant real memory file such as a lowercase agents.md, whose
# CLAUDE.md symlink would carry an uppercase literal target that dangles on a
# case-sensitive filesystem (issue #389).
# Never converts an already-real, regular CLAUDE.md into a symlink. Git on
# Windows checkouts commonly runs with core.symlinks=false, where a tracked
# symlink materializes on checkout as a plain text file containing its link
# target rather than a real symlink, so any agent that reads CLAUDE.md
# silently stops seeing project instructions. A project may already have hit
# and reverted exactly that (see the site-feasibility project's
# docs/STATUS.md:187 at the time this was written); re-promoting its real
# CLAUDE.md back into a symlink would reintroduce the same silent breakage,
# so promotion always copies instead, regardless of whether this worktree's
# own filesystem happens to support symlinks.
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

# Trailing marker line this script appends to a real (non-symlink) CLAUDE.md
# duplicate it writes. Its presence is how a later run tells "this CLAUDE.md
# is a duplicate this helper owns and may resync" apart from "this CLAUDE.md
# is hand-authored and a content mismatch is a genuine conflict" - see
# claude_has_marker() below. Absence must fail safe, so an unmarked file
# always keeps today's hard-conflict-on-mismatch behavior.
CLAUDE_SYNC_MARKER='<!-- fm-ensure-agents-md: this CLAUDE.md is a synced duplicate of AGENTS.md, written because symlinks are not reliable here; edit AGENTS.md instead, then re-run fm-ensure-agents-md.sh -->'

# Detect AGENTS.md's own line-ending convention into AGENTS_EOL, so every line
# this script writes into or alongside that content (the maintenance section,
# the CLAUDE.md sync marker) matches it instead of forcing LF. A CRLF worktree
# is the normal case on the Windows checkouts this helper's real-duplicate mode
# exists for, and a marker written with the wrong ending is unrecognizable
# after a core.autocrlf checkout normalizes the file.
AGENTS_EOL=$'\n'
detect_agents_eol() {
  AGENTS_EOL=$'\n'
  if [ -f "$AGENTS" ] && LC_ALL=C grep -q $'\r$' "$AGENTS"; then
    AGENTS_EOL=$'\r\n'
  fi
}

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to AGENTS.md when it
# is absent. Sets MAINT_INJECTED=1 when it appends and 0 when the section is
# already present, so callers can report whether the file changed.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  if grep -Fqx '## Maintaining this file' "$AGENTS" ||
    grep -Fqx $'## Maintaining this file\r' "$AGENTS"; then
    return 0
  fi
  local sep=''
  detect_agents_eol
  local eol=$AGENTS_EOL
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$AGENTS"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Remove the symlink probe and drop the cleanup traps installed for it, so the
# rest of the run is back to the script's default signal handling.
clear_probe() {
  rm -f "$1" 2>/dev/null || true
  trap - EXIT INT TERM
}

# Detect whether $DIR's working tree sits on WSL's DrvFs, the bind that
# exposes a native Windows drive (e.g. C:\) into Linux, normally mounted
# under /mnt/<letter> - the captain's own production checkouts live there.
# `ln -s` succeeds on DrvFs and a brand-new repo has no core.symlinks
# recorded yet, so neither of claude_symlink_unsafe()'s other two signals
# sees the danger, yet a symlink written from here still lands on the real
# Windows filesystem, where native Windows git commonly defaults to
# core.symlinks=false and materializes a tracked symlink as the same dead
# text stub this whole change exists to prevent. Read the real mount table
# instead of matching the path string, so an unrelated /mnt/<x> mount (a
# genuinely mounted ext4 image, say) is not penalized, and a DrvFs mount
# elsewhere is still caught. DrvFs surfaces as fstype "drvfs" directly on
# older WSL, or as fstype "9p" carrying "aname=drvfs" in its mount options on
# current WSL2 (confirmed against a live WSL2 host: `C:\ on /mnt/c type 9p
# (...,aname=drvfs;path=C:\...)`); a same-fstype "9p" mount without that
# option, such as WSL's own driver mount, is not DrvFs and is left alone.
# Reads through $FM_PROC_ROOT_OVERRIDE (defaulting to /proc, the same
# fake-/proc override other scripts in this repo already use for tests) so a
# colocated test can point it at a fixture mount table instead of the real
# machine's.
on_drvfs() {
  local mounts=${FM_PROC_ROOT_OVERRIDE:-/proc}/mounts
  [ -r "$mounts" ] || return 1
  local best_point='' best_type='' best_opts='' point type opts rest
  while read -r _ point type opts rest; do
    case "$DIR" in
      "$point"|"$point"/*)
        if [ "${#point}" -ge "${#best_point}" ]; then
          best_point=$point
          best_type=$type
          best_opts=$opts
        fi
        ;;
    esac
  done < "$mounts"
  case "$best_type" in
    drvfs) return 0 ;;
    9p)
      case "$best_opts" in
        *aname=drvfs*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Decide whether a CLAUDE.md symlink written in $DIR can be trusted to
# survive as a real symlink for the next checkout of this repository, rather
# than degrading into a plain-text stub holding the link target (the
# site-feasibility regression described above). Returns success (0 = "true",
# unsafe) when a symlink should NOT be created here. Three independent,
# empirically-checked signals feed this rather than guessing from the path:
#   - git's own effective core.symlinks for this exact repository. Git
#     probes filesystem symlink support at clone/init time and records the
#     result; an explicit "false" is git's own record that it will
#     materialize a tracked symlink here as a plain text file on checkout,
#     so it is trusted outright without a second-guessing probe.
#   - on_drvfs() above: a fresh repo has no core.symlinks recorded yet, and
#     DrvFs itself lets Linux create real symlink objects, so this signal is
#     the only thing that catches a brand-new repo on the captain's own
#     Windows-backed checkouts before the ln -s probe below would otherwise
#     wave it through.
#   - a live filesystem probe: actually create and remove a throwaway
#     symlink in $DIR. This catches worktrees where git has not recorded
#     core.symlinks and this is not a DrvFs mount (a bare `git init` on a
#     plain filesystem with symlinks disabled some other way) and any other
#     reason symlink creation might fail or silently degrade to a regular
#     file.
# Any one signal alone is enough to call it unsafe; all three must pass for a
# symlink to be created.
claude_symlink_unsafe() {
  local core_symlinks probe
  core_symlinks=$(git -C "$DIR" config --bool core.symlinks 2>/dev/null || true)
  if [ "$core_symlinks" = "false" ]; then
    return 0
  fi
  if on_drvfs; then
    return 0
  fi
  probe="$DIR/.fm-ensure-agents-md.symlink-probe.$$"
  rm -f "$probe" 2>/dev/null || true
  trap 'rm -f "$probe" 2>/dev/null || true' EXIT
  trap 'rm -f "$probe" 2>/dev/null || true; trap - INT; kill -INT $$' INT
  trap 'rm -f "$probe" 2>/dev/null || true; trap - TERM; kill -TERM $$' TERM
  if ! ln -s "probe-target" "$probe" 2>/dev/null; then
    clear_probe "$probe"
    return 0
  fi
  if [ ! -L "$probe" ]; then
    clear_probe "$probe"
    return 0
  fi
  clear_probe "$probe"
  return 1
}

# Emit the exact bytes a real (non-symlink) CLAUDE.md duplicate must hold:
# AGENTS.md's current content plus the trailing sync marker on a line of its
# own. AGENTS.md need not end with a newline (a hand-trimmed or promoted
# newline-less memory file is a normal input), so start the marker's line
# when the content does not already end one - otherwise the marker would be
# glued onto the last content line and claude_has_marker() could never
# recognize the file again. Both the writer and the in-sync comparison go
# through here so they cannot drift apart.
emit_synced_claude_content() {
  detect_agents_eol
  cat "$AGENTS"
  if [ -s "$AGENTS" ] && [ -n "$(tail -c 1 "$AGENTS")" ]; then
    printf '%s' "$AGENTS_EOL"
  fi
  printf '%s%s' "$CLAUDE_SYNC_MARKER" "$AGENTS_EOL"
}

# Write a real (non-symlink) CLAUDE.md as AGENTS.md's current content plus
# the trailing sync marker, so a later run can tell this file apart from a
# hand-authored one. AGENTS.md must already hold its final content
# (including any injected maintenance section) before this runs.
write_claude_duplicate() {
  emit_synced_claude_content > "$CLAUDE"
}

# True when CLAUDE.md's own last line is exactly the sync marker, i.e. this
# file is a duplicate this helper wrote rather than something hand-authored.
# Checked against the file's real, current content - never assumed from
# knowing this helper created it in some earlier run. A trailing CR is
# ignored, so a marked duplicate stays recognizable after a CRLF checkout
# rewrites the whole file's line endings.
claude_has_marker() {
  [ -f "$CLAUDE" ] || return 1
  local last
  last=$(tail -n 1 "$CLAUDE" 2>/dev/null || true)
  [ "${last%$'\r'}" = "$CLAUDE_SYNC_MARKER" ]
}

# True when CLAUDE.md's content is exactly AGENTS.md's content plus the
# trailing sync marker - the steady state right after write_claude_duplicate.
claude_matches_agents_synced() {
  emit_synced_claude_content | cmp -s - "$CLAUDE"
}

# Seed AGENTS.md from an existing real CLAUDE.md during promotion, dropping a
# trailing sync-marker line when CLAUDE.md carries one. A marked CLAUDE.md can
# reach the promotion path whenever AGENTS.md disappears out of band (a stray
# deletion, a partial checkout, a reverted commit) while its marked mirror
# survives; copying the marker verbatim would bake this helper's own machine
# line into the real memory file every agent session reads, and the next
# sync_claude() would then append a second one.
seed_agents_from_claude() {
  if claude_has_marker; then
    sed '$d' "$CLAUDE" > "$AGENTS"
  else
    cp "$CLAUDE" "$AGENTS"
  fi
}

# Point CLAUDE.md at AGENTS.md. AGENTS.md must already hold its final content
# (including any injected maintenance section) before this runs, so a
# real-file duplicate starts in sync with it.
create_claude() {
  if claude_symlink_unsafe; then
    write_claude_duplicate
  else
    ln -s "$AGENTS" "$CLAUDE"
  fi
}

# Refresh a real (non-symlink) CLAUDE.md so its content matches AGENTS.md
# again, e.g. after ensure_maintenance_section appended to AGENTS.md, or to
# resync a marked duplicate that drifted because AGENTS.md changed. A no-op
# when CLAUDE.md is a symlink, since it already resolves live.
sync_claude() {
  [ -L "$CLAUDE" ] && return 0
  write_claude_duplicate
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a CLAUDE.md symlink whose uppercase
# literal target dangles once the tree is checked out on a case-sensitive
# filesystem. Reading the real directory entries catches the mismatch on both
# filesystem kinds; surface it for manual reconciliation instead of linking blindly.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md links portably" >&2
        exit 1
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    if is_correct_claude_symlink; then
      ensure_maintenance_section
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $DIR"
      fi
      exit 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section
    create_claude
    if [ -L "$CLAUDE" ]; then
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and symlinked CLAUDE.md -> AGENTS.md in $DIR"
      else
        echo "symlinked: CLAUDE.md -> AGENTS.md in $DIR"
      fi
    else
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and created a real CLAUDE.md kept in sync with it in $DIR (symlinks unreliable here)"
      else
        echo "synced: created a real CLAUDE.md kept in sync with AGENTS.md in $DIR (symlinks unreliable here)"
      fi
    fi
    exit 0
  fi
  if [ -f "$CLAUDE" ]; then
    # Byte-identical (a legacy duplicate from before the sync marker
    # existed, or a hand-authored file that happens to match verbatim) and
    # an already-marked, already-synced duplicate both count as in sync.
    if cmp -s "$AGENTS" "$CLAUDE" || claude_matches_agents_synced; then
      claude_was_marked=1
      claude_has_marker || claude_was_marked=0
      ensure_maintenance_section
      sync_claude
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and CLAUDE.md in $DIR"
      elif [ "$claude_was_marked" -eq 0 ]; then
        # sync_claude() just rewrote CLAUDE.md's bytes to add the sync
        # marker (a legacy duplicate from before it existed) - report the
        # actual change rather than "unchanged", since a crewmate reads
        # this line to decide whether anything needs committing.
        echo "updated: added the sync marker to CLAUDE.md in $DIR"
      else
        echo "unchanged: AGENTS.md and CLAUDE.md are real, synced files in $DIR"
      fi
      exit 0
    fi
    if claude_has_marker; then
      # This CLAUDE.md is a duplicate this helper wrote, not a hand-authored
      # file, so a mismatch here means AGENTS.md moved on since the last
      # sync (the normal workflow: edit AGENTS.md, then re-run this
      # helper) rather than a genuine conflict - resync instead of refusing.
      ensure_maintenance_section
      sync_claude
      echo "synced: refreshed CLAUDE.md to match updated AGENTS.md in $DIR"
      exit 0
    fi
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR with different content; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$CLAUDE" ]; then
  if is_correct_claude_symlink; then
    write_skeleton
    echo "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    # A real, regular CLAUDE.md already here is deliberate project content.
    # Promote it into the AGENTS.md convention by copying, never by moving
    # it into a symlink target: see the file header for why an already-real
    # CLAUDE.md is never turned into a symlink here.
    seed_agents_from_claude
    ensure_maintenance_section
    sync_claude
    echo "promoted: copied CLAUDE.md content into AGENTS.md; CLAUDE.md is now a managed mirror of AGENTS.md in $DIR - edit AGENTS.md from now on, not CLAUDE.md"
    exit 0
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
create_claude
if [ -L "$CLAUDE" ]; then
  echo "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $DIR"
else
  echo "created: AGENTS.md and a real CLAUDE.md kept in sync with it in $DIR (symlinks unreliable here)"
fi
