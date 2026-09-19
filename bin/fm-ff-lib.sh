# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# A REMOTE secondmate home follows that same primary commit. Its host cannot read
# this object store, so bin/fm-spawn.sh and bin/fm-bootstrap.sh hand the commit to
# bin/fm-remote-secondmate-control.sh, which imports it on that host and then runs
# THIS ff_target with it as the base, so the guards below stay the only copy of the
# ancestry rules.
#
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A local standalone clone moves through that path
# only when it already has the target; otherwise it is skipped until the origin
# path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# secondmate's backlog, projects, or in-flight work.
# The seeded .fm-secondmate-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# Locally leased homes start at a detached HEAD on the default branch, so their
# fast-forward advances HEAD only and never moves the shared default branch or
# any other worktree's checkout. A standalone remote home may instead advance
# its checked-out default branch under the same guard.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# GitHub identity comes from the configured fetch URL, never the push URL
# (which can be a gate or a different repository). Git still applies insteadOf
# transport rewrites when it dials that URL. Non-GitHub origins retain ordinary
# Git sync.
#
# Recognize github.com across every spelling Git accepts instead of a fixed set
# of literals: any scheme URL, with optional userinfo and port, and the scp-like
# [user@]host:path shorthand. Prints <owner>/<repo> for a GitHub remote; a
# remote that definitively lives somewhere else (another host, a local path)
# returns FF_NOT_GITHUB, and a spelling that cannot be placed at all returns
# FF_UNCLASSIFIED so callers refuse loudly instead of skipping silently.
FF_NOT_GITHUB=1
FF_UNCLASSIFIED=2
ff_github_repo() { # <url>
  local url=$1 rest host path
  case "$url" in
    file://*|/*|./*|../*|~*) return "$FF_NOT_GITHUB" ;;
    *://*) rest=${url#*://} ;;
    *:*)
      case "${url%%:*}" in ""|*/*) return "$FF_UNCLASSIFIED" ;; esac
      rest="${url%%:*}/${url#*:}" ;;
    *) return "$FF_NOT_GITHUB" ;;
  esac
  host=${rest%%/*}
  [ "$host" != "$rest" ] || return "$FF_UNCLASSIFIED"
  path=${rest#*/}
  host=${host##*@}
  host=${host%%:*}
  case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
    github.com) ;;
    "") return "$FF_UNCLASSIFIED" ;;
    *) return "$FF_NOT_GITHUB" ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  [[ "$path" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || return "$FF_UNCLASSIFIED"
  printf '%s\n' "$path"
}

# Fork discovery needs authenticated gh-axi and node. When they cannot answer,
# fork-ness is UNKNOWN rather than absent, so the ordinary Git origin path stays
# intact instead of blocking every update - but FF_FORK_UNVERIFIED records the
# reason so no caller can read the result as proof the checkout is current.
FF_FORK_UNVERIFIED=""
ff_discovery_warn() { # <repo> <reason>
  FF_FORK_UNVERIFIED="$2"
  printf 'fork sync: discovery unavailable for %s: %s; updating from origin unverified\n' \
    "$1" "$2" >&2
}

# Before an origin update, discover GitHub's fork relationship, even without an
# upstream remote. Use the parent's default branch only when its name matches
# the fork default; a different default requires operator reconciliation.
# Fetch both tips, prove ancestry, and push the parent's existing commit to the
# exact fork fetch URL with an ordinary non-forced push. No local branch, merge
# commit, configured push URL, or other ref is involved. A fork ahead of its
# parent is already synchronized; once a fork IS established, divergence and
# every transport failure fail closed. An origin spelling that cannot be
# classified at all also fails closed. An origin GitHub reports as authoritative
# returns before FF_ORIGIN_DEFAULT is set, so the no-fork case stays a no-op.
# The final origin fetch happens only after this succeeds. FF_FETCH_ERROR
# carries an actionable failure to ff_target.
ff_sync_origin_fork() { # <dir>
  local dir=$1 url status repo metadata record fork name branch parent
  local parent_branch source fork_tip parent_tip out
  FF_ORIGIN_DEFAULT=""
  FF_FORK_UNVERIFIED=""
  # Several values is the ordinary push-to-mirrors config; Git fetches from the
  # first, and the configured spelling is the identity insteadOf must not rewrite.
  url=$(git -C "$dir" config --get-all remote.origin.url | head -1)
  [ -n "$url" ] || return 1
  repo=$(ff_github_repo "$url") || status=$?
  if [ -z "$repo" ]; then
    [ "$status" = "$FF_NOT_GITHUB" ] && return 0
    FF_FETCH_ERROR="fork discovery failed: unrecognizable origin URL $url"
    return 1
  fi
  metadata=$(gh-axi api "/repos/$repo" --hostname github.com --full --jq \
    '{fork: .fork, name: .full_name, branch: .default_branch, parent: (.parent.full_name // "-"), parentBranch: (.parent.default_branch // "-")}' 2>&1) || {
    ff_discovery_warn "$repo" "$(first_line "$metadata")"
    return 0
  }
  # Decode only this flat, caller-selected TOON record; refuse missing, duplicate,
  # extra, or malformed fields instead of interpreting an error body as no fork.
  record=$(printf '%s\n' "$metadata" | node -e '
    let input = "";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try {
        const keys = ["fork", "name", "branch", "parent", "parentBranch"];
        const fields = {};
        for (const line of input.trim().split("\n")) {
          const match = line.match(/^([A-Za-z]+): (.+)$/);
          if (!match || !keys.includes(match[1]) || match[1] in fields) throw Error();
          const raw = match[2];
          fields[match[1]] = raw.startsWith("\"") ? JSON.parse(raw) : raw;
        }
        if (keys.some(key => typeof fields[key] !== "string" || !fields[key] || /\s/.test(fields[key]))) throw Error();
        if (!["true", "false"].includes(fields.fork)) throw Error();
        process.stdout.write(keys.map(key => fields[key]).join("\t"));
      } catch { process.exitCode = 1; }
    });' 2>/dev/null) || {
    ff_discovery_warn "$repo" "unreadable repository metadata"
    return 0
  }
  IFS=$'\t' read -r fork name branch parent parent_branch <<< "$record"
  if [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
    ff_discovery_warn "$repo" "metadata describes $name"
    return 0
  fi
  [ "$fork" = true ] || return 0

  # A fork IS established from here on, so every remaining failure is a real
  # synchronization failure and must stop the update.
  FF_FETCH_ERROR="fork sync failed: $repo reports an unusable default branch $branch"
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || return 1
  FF_ORIGIN_DEFAULT=$branch
  FF_FETCH_ERROR="fork sync failed: $repo reports an unusable parent $parent"
  ff_github_repo "https://github.com/$parent" >/dev/null || return 1
  [ "$parent" != "$name" ] || return 1
  FF_FETCH_ERROR="fork sync refused: $repo default $branch differs from $parent default $parent_branch"
  [ "$branch" = "$parent_branch" ] || return 1

  # Derive the parent URL from origin's own transport; no separately named
  # upstream remote is required.
  case "$url" in
    git@*) source="git@github.com:$parent.git" ;;
    ssh://*) source="ssh://git@github.com/$parent.git" ;;
    *) source="https://github.com/$parent.git" ;;
  esac
  FF_FETCH_ERROR="fork sync failed: cannot fetch $repo/$branch"
  git -C "$dir" fetch --quiet --no-tags -- "$url" "refs/heads/$branch" 2>/dev/null || return 1
  fork_tip=$(git -C "$dir" rev-parse --verify FETCH_HEAD) || return 1
  FF_FETCH_ERROR="fork sync failed: cannot fetch $parent/$parent_branch"
  git -C "$dir" fetch --quiet --no-tags -- "$source" "refs/heads/$parent_branch" 2>/dev/null || return 1
  parent_tip=$(git -C "$dir" rev-parse --verify FETCH_HEAD) || return 1
  git -C "$dir" merge-base --is-ancestor "$parent_tip" "$fork_tip" 2>/dev/null && return 0
  FF_FETCH_ERROR="fork sync refused: $repo/$branch diverged from $parent/$parent_branch"
  git -C "$dir" merge-base --is-ancestor "$fork_tip" "$parent_tip" 2>/dev/null || return 1
  if ! out=$(git -C "$dir" -c push.followTags=false push --porcelain -- "$url" "$parent_tip:refs/heads/$branch" 2>&1); then
    FF_FETCH_ERROR="fork sync failed: cannot fast-forward $repo/$branch: $(first_line "$out")"
    return 1
  fi
  printf 'fork sync: fast-forwarded %s/%s from %s/%s\n' "$repo" "$branch" "$parent" "$parent_branch"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches. Each memo record is "<common-dir>\t<fork
# verdict>": the verdict belongs to that store, so a later worktree of it is
# labelled from its own discovery rather than from whichever store was most
# recently fetched.
FETCHED=""
FF_FETCH_ERROR=""
# Sticky origin failure flag consumed by fm-update.sh after its fleet sweep.
# Raised at exactly TWO places, both carrying the SAME verdict - an established
# fork that could not be synchronized: the fork-synchronization branch below,
# for a local or local-secondmate origin update, and fm-update.sh's remote
# sweep when a host answers REMOTE_UPDATE_FAILED_STATUS, which is that host's
# own copy of this branch reporting across the wire. On either route an
# ordinary transport failure (offline, VPN, an unreachable host) stays a
# reported skip. No other site decides this.
FF_UPDATE_FAILED=0
# Sticky run-level answer to "did this run actually verify currency". Rolled up
# from the same per-store FF_FORK_UNVERIFIED the status labels read, at the one
# point where it is known, so a label and this verdict cannot disagree.
# fm-update.sh publishes it and the remote route carries it over the wire.
FF_RUN_VERIFIED=yes
fetch_once() {
  local dir=$1 common record
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    while IFS= read -r record; do
      [ "${record%%$'\t'*}" = "$common" ] || continue
      FF_FORK_UNVERIFIED=${record#*$'\t'}
      return 0
    done <<< "$FETCHED"
  fi
  FF_FETCH_ERROR="fetch failed"
  if ! ff_sync_origin_fork "$dir"; then
    FF_UPDATE_FAILED=1
    return 1
  fi
  FF_FETCH_ERROR="fetch failed"
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    if [ -n "$FF_ORIGIN_DEFAULT" ]; then
      # Fetch the actual default explicitly even with a narrow clone refspec.
      git -C "$dir" fetch --quiet --no-tags origin \
        "+refs/heads/$FF_ORIGIN_DEFAULT:refs/remotes/origin/$FF_ORIGIN_DEFAULT" 2>/dev/null || return 1
      git -C "$dir" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$FF_ORIGIN_DEFAULT" || return 1
    fi
    [ -n "$common" ] && FETCHED="$FETCHED$common"$'\t'"$FF_FORK_UNVERIFIED"$'\n'
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md imports via @AGENTS.md), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

# Translate one remote home sync leg's failure into an operator-actionable
# reason. The remote leg refuses a command shape it does not recognize with this
# status, which on this leg can only mean that host's Firstmate copy predates the
# parent-targeted sync it was just asked for; every other failure already carries
# its own diagnostic.
REMOTE_SYNC_UNSUPPORTED_STATUS=2
remote_sync_failure_reason() { # <exit-status> <output>
  if [ "$1" = "$REMOTE_SYNC_UNSUPPORTED_STATUS" ]; then
    printf '%s\n' "the Firstmate copy on that host is too old to sync to this primary's commit; run /updatefirstmate"
    return 0
  fi
  first_line "$2"
}

# cmd_update raises this distinct status when a remote host's OWN fm-update.sh
# exits nonzero, which only happens when ITS FF_UPDATE_FAILED classifier fired
# (a real fork-synchronization failure, never an ordinary transport hiccup).
# fm-update.sh's remote sweep checks fm-on.sh's exit status against it so that
# classifier's verdict crosses the remote boundary as the same sticky
# FF_UPDATE_FAILED result the local route already sets, instead of collapsing
# into an ordinary skip the caller cannot distinguish from ubiquitous
# transport failure.
REMOTE_UPDATE_FAILED_STATUS=3

dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print; exit }'
  else
    git -C "$dir" status --porcelain 2>/dev/null | head -1
  fi
}

# List this home's LIVE secondmate direct reports from state/<id>.meta records.
# The meta file is the liveness signal; data/secondmates.md is only the fallback
# for durable fields such as home= when an older/incomplete meta lacks them.
# Output is pipe-delimited: id|home|window|meta-file.
live_secondmate_meta_records() {
  local state=$1 registry=${2:-} meta id home window
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$home" ] && [ -n "$registry" ]; then
      home=$(secondmate_registry_field "$registry" "$id" home || true)
    fi
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s|%s|%s|%s\n' "$id" "$home" "$window" "$meta"
  done
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - synchronize a GitHub fork via ff_sync_origin_fork above, then
#                  fetch origin and advance to origin/<default>; requires an
#                  origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# dirty, diverged, or wrong-branch target and leave its work untouched.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out
  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      FF_RUN_VERIFIED=no
      echo "$label: skipped: $FF_FETCH_ERROR"
      return 0
    fi
    [ -z "$FF_FORK_UNVERIFIED" ] || FF_RUN_VERIFIED=no
  fi
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  if [ "$base_mode" = origin ]; then
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    if [ -n "$FF_FORK_UNVERIFIED" ] && [ "$base_mode" = origin ]; then
      echo "$label: cannot confirm current: fork sync unavailable ($FF_FORK_UNVERIFIED)"
    else
      echo "$label: already current"
    fi
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one secondmate home, accumulating its stable
# fm-<id> task selector into FF_NUDGE_WINDOWS when it should be live-converged.
# Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a
# live window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# firstmate repo itself (FM_ROOT) is never processed as its own secondmate, and
# each resolved home is processed at most once.
#
# Two optional caller hooks fire from here, each at most once per resolved home:
#   fm_ff_after_instruction_update <id> <home> <window> <instr>
#     the nudge-shaped hook: only for an advance that changed the instruction
#     surface, and only under nudge_requires_instr=yes.
#   fm_ff_after_secondmate_settled <id> <home> <window> <status> <instr>
#     the settled-state hook: for every home this sweep left AT the base with a
#     live window, whether it advanced (status=updated) or was already there
#     (status=current). A home that was SKIPPED is never settled, so a dirty,
#     diverged, offline, or unsafe home never reaches this hook and nothing here
#     forces, stashes, or discards its work. /updatefirstmate uses this hook to
#     reach every live mate that is genuinely on the new bytes, including the
#     ones that needed no advance to get there.
# An undefined hook is simply not called.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} home_real fm_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "secondmate $id" "$base_mode" yes yes
  if [ -n "$window" ] && { [ "$FF_STATUS" = "updated" ] || [ "$FF_STATUS" = "current" ]; } \
    && type fm_ff_after_secondmate_settled >/dev/null 2>&1; then
    fm_ff_after_secondmate_settled "$id" "$home_real" "$window" "$FF_STATUS" "$FF_INSTR"
  fi
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
    if [ "$nudge_requires_instr" = yes ] && [ -n "$FF_INSTR" ] \
      && type fm_ff_after_instruction_update >/dev/null 2>&1; then
      fm_ff_after_instruction_update "$id" "$home_real" "$window" "$FF_INSTR"
    fi
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_secondmate. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
# The registry argument is only for home= fallback on older or incomplete meta records.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$FM_HOME/data/secondmates.md} id home window meta
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta; do
    if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr"
  done < <(live_secondmate_meta_records "$state" "$registry")
}
