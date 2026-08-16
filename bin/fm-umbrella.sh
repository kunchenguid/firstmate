#!/usr/bin/env bash
# Stand up or tear down an UMBRELLA workspace: a captain-driven cross-repo lab.
#
# An umbrella is a workspace, not an autonomous task. It checks out several
# project repos side by side as isolated git worktrees so the captain (or one
# agent the captain drives directly) can DESIGN a feature that spans those repos
# with every repo visible at once - the phase where the human is needed most and
# where a per-brief delegation loses the most fidelity. See
# docs/cross-repo-workspaces.md for the full rationale and how an umbrella feeds
# a delegated "epic" of ordinary single-repo ship tasks.
#
# What an umbrella deliberately is NOT: it launches no autonomous worker, arms no
# merge poll, and creates no branch. There is nothing for the watcher, fm-spawn,
# fm-teardown, or fm-pr-check to reason about, so its metadata lives under
# umbrellas/<umbrella-id>/umbrella.meta (NOT state/<id>.meta) and no single-repo task
# mechanism ever sees it. That is what makes this construct zero-risk to the
# existing task flow.
#
# Its durable output is umbrellas/<umbrella-id>/DESIGN.md - the cross-repo contract.
# The repos/ worktrees are scratch, exactly like a scout worktree: teardown
# discards them once DESIGN.md exists, and DESIGN.md survives teardown. The
# contract worked out here is expected to LAND FIRST as its own ordinary task
# before any dependent per-repo work is delegated.
#
# Worktrees are created directly with `git worktree add --detach` against each
# project's clone under projects/<name>, at the fetched default-branch tip when
# an origin is present (a fresh, isolated base), falling back to the local
# default branch when there is no origin. This is the same isolation firstmate
# guarantees for a task worktree; the treehouse pool is the supervised-crew path,
# not the lab path.
#
# Usage:
#   fm-umbrella.sh create <umbrella-id> --repos <name>,<name>,...
#   fm-umbrella.sh teardown <umbrella-id> [--force]
#   fm-umbrella.sh list
#
#   create    Allocate one isolated worktree per named project under
#             umbrellas/<umbrella-id>/repos/<name>, write a DESIGN.md and a cross-repo
#             AGENTS.md skeleton, and record umbrellas/<umbrella-id>/umbrella.meta.
#             Transactional: any failure rolls back every worktree and the dir.
#             Refuses if the umbrella id already exists. Each <name> must resolve
#             to a git clone at projects/<name>.
#   teardown  Return every worktree and remove umbrella.meta and the cross-repo
#             AGENTS.md, KEEPING DESIGN.md as the durable artifact. Refuses unless
#             DESIGN.md exists and is non-empty; --force skips that gate. Scratch
#             worktrees are discarded even if dirty, but their `git status` is
#             printed first so nothing is discarded silently.
#   list      Print each umbrella id, its repos, and its DESIGN.md state.
#
# --repos names are comma-separated with no spaces. The captain enters the lab
# with `cd umbrellas/<umbrella-id> && <your coding agent>`; AGENTS.md treats direct
# captain work in that workspace as authoritative.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
if [ -n "${FM_UMBRELLAS_OVERRIDE:-}" ]; then
  UMBRELLAS=$(resolve_directory_input FM_UMBRELLAS_OVERRIDE "$FM_UMBRELLAS_OVERRIDE") || exit 1
else
  UMBRELLAS="$FM_HOME/umbrellas"
fi
if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then
  PROJECTS=$(resolve_directory_input FM_PROJECTS_OVERRIDE "$FM_PROJECTS_OVERRIDE") || exit 1
else
  PROJECTS="$FM_HOME/projects"
fi

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

err() { echo "error: $*" >&2; }

# A safe umbrella id uses the same character class as a task id: no path
# traversal, no leading dot, no shell metacharacters.
umbrella_id_valid() {
  case "${1-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A project name must be a single clean path segment so it can only ever resolve
# to a direct child of projects/ and a direct child of repos/.
repo_name_valid() {
  case "${1-}" in
    ''|.|..|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Resolve a clone's default branch: origin/HEAD if known, else a local main or
# master, else the currently checked-out branch. Mirrors the per-script
# default_branch helpers already used across bin/.
default_branch() {
  local dir=$1 ref
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  if git -C "$dir" show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
    return 0
  fi
  if git -C "$dir" show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
    return 0
  fi
  git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || return 1
}

# The freshest commit to base a lab worktree on: origin/<default> when an origin
# provides it, else the local default branch, else HEAD. Fetch failure is not
# fatal - a repo with no origin (or an offline clone) still yields a usable local
# base, and the caller only needs a clean isolated checkout to design against.
umbrella_base_ref() {
  local clone=$1 default
  git -C "$clone" fetch --quiet origin 2>/dev/null || true
  git -C "$clone" remote set-head origin --auto >/dev/null 2>&1 || true
  default=$(default_branch "$clone") || return 1
  if git -C "$clone" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}" >/dev/null 2>&1; then
    printf 'origin/%s\n' "$default"
    return 0
  fi
  if git -C "$clone" rev-parse --verify --quiet "refs/heads/$default^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi
  printf 'HEAD\n'
}

umbrella_meta_get() {  # <meta-file> <key>
  [ -f "$1" ] || return 1
  local v
  v=$(grep "^$2=" "$1" | tail -1) || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "${v#*=}"
}

# ---------------------------------------------------------------------------

cmd_create() {
  local id="" repos_csv=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repos) repos_csv=${2-}; shift 2 || { err "--repos needs a value"; exit 2; } ;;
      --repos=*) repos_csv=${1#--repos=}; shift ;;
      -*) err "unknown flag: $1"; exit 2 ;;
      *) if [ -z "$id" ]; then id=$1; shift; else err "unexpected argument: $1"; exit 2; fi ;;
    esac
  done

  if [ -z "$id" ] || [ -z "$repos_csv" ]; then
    err "usage: fm-umbrella.sh create <umbrella-id> --repos <name>,<name>,..."
    exit 2
  fi
  if ! umbrella_id_valid "$id"; then
    err "invalid umbrella id: $id"
    exit 2
  fi

  local umbrella_dir="$UMBRELLAS/$id"
  local meta="$umbrella_dir/umbrella.meta"
  if [ -e "$umbrella_dir" ] || [ -e "$STATE/$id.meta" ]; then
    err "id already in use: $id (umbrellas/$id or state/$id.meta exists)"
    exit 1
  fi

  # Parse and validate the repo list up front, before any mutation.
  local -a names=()
  local IFS_SAVE=$IFS name
  IFS=','
  # shellcheck disable=SC2206  # deliberate word-split on comma
  local raw=($repos_csv)
  IFS=$IFS_SAVE
  for name in "${raw[@]}"; do
    [ -n "$name" ] || continue
    if ! repo_name_valid "$name"; then
      err "invalid repo name: $name"
      exit 2
    fi
    local clone="$PROJECTS/$name"
    if [ ! -d "$clone" ] || ! git -C "$clone" rev-parse --git-dir >/dev/null 2>&1; then
      err "repo '$name' is not a git clone at projects/$name; add or clone it first"
      exit 1
    fi
    names+=("$name")
  done
  if [ "${#names[@]}" -eq 0 ]; then
    err "--repos listed no usable repositories"
    exit 2
  fi

  # From here on, roll back everything on any failure.
  local -a created_wt=()
  local -a created_clone=()
  local ok=0
  rollback() {
    [ "$ok" = 1 ] && return 0
    local i
    for i in "${!created_wt[@]}"; do
      git -C "${created_clone[$i]}" worktree remove --force "${created_wt[$i]}" >/dev/null 2>&1 \
        || rm -rf -- "${created_wt[$i]}"
    done
    for i in "${!created_clone[@]}"; do
      git -C "${created_clone[$i]}" worktree prune >/dev/null 2>&1 || true
    done
    rm -rf -- "$umbrella_dir"
  }
  trap rollback EXIT
  trap 'exit 1' HUP INT TERM

  mkdir -p "$umbrella_dir/repos" || { err "could not create $umbrella_dir/repos"; exit 1; }

  local repos_field=""
  for name in "${names[@]}"; do
    local clone="$PROJECTS/$name"
    local wt="$umbrella_dir/repos/$name"
    local base
    base=$(umbrella_base_ref "$clone") || { err "could not resolve a base for '$name'"; exit 1; }
    if ! git -C "$clone" worktree add --detach --quiet "$wt" "$base"; then
      err "could not create worktree for '$name' at $wt (base $base)"
      exit 1
    fi
    created_wt+=("$wt")
    created_clone+=("$clone")
    # Isolation assertion: the new worktree root must be itself, never the clone.
    local wt_real clone_real wt_top
    wt_real=$(cd "$wt" 2>/dev/null && pwd -P || true)
    clone_real=$(cd "$clone" 2>/dev/null && pwd -P || true)
    wt_top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -z "$wt_real" ] || [ "$wt_real" = "$clone_real" ] || [ "$wt_real" != "$(cd "$wt_top" 2>/dev/null && pwd -P || true)" ]; then
      err "worktree for '$name' did not isolate from the clone (resolved '$wt_real', clone '$clone_real', root '$wt_top')"
      exit 1
    fi
    if [ -n "$repos_field" ]; then repos_field="$repos_field,$name"; else repos_field="$name"; fi
  done

  # DESIGN.md - the durable output.
  cat > "$umbrella_dir/DESIGN.md" <<EOF
# DESIGN: $id

Cross-repo design contract. This file is the durable output of the umbrella and
survives teardown. Land what it specifies as its own ordinary task BEFORE
delegating any dependent per-repo work (see docs/cross-repo-workspaces.md).

Repos in this umbrella: $repos_field

## Problem


## Contract to land first
<!-- The mergeable artifact - OpenAPI/proto/types/schema - that turns every
     dependent per-repo task from ambiguous into specified. -->


## Per-repo work (delegate after the contract lands)
EOF
  for name in "${names[@]}"; do
    printf -- '- %s: \n' "$name" >> "$umbrella_dir/DESIGN.md"
  done

  # Cross-repo AGENTS.md - orientation for whoever works in the lab.
  cat > "$umbrella_dir/AGENTS.md" <<EOF
# Umbrella workspace: $id

This is a cross-repo design lab, not a shipping checkout. Each directory under
\`repos/\` is an isolated git worktree of one project, at a detached HEAD on a
fresh default-branch base.

Repos: $repos_field

- Design across all repos here; capture the contract in \`DESIGN.md\`.
- Scratch commits in these worktrees are discarded at teardown - they are a
  scratchpad, not the deliverable.
- The deliverable is \`DESIGN.md\` plus a contract that ships as its own task.
- Do not open PRs from here; per-repo implementation is delegated as ordinary
  single-repo tasks once the contract has landed.
EOF

  # Metadata - deliberately under umbrellas/ (a sibling of data/, never state/), invisible to the task/watcher scan.
  {
    printf 'kind=umbrella\n'
    printf 'umbrella_id=%s\n' "$id"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repos=%s\n' "$repos_field"
    for name in "${names[@]}"; do
      printf 'clone_%s=%s\n' "$name" "$PROJECTS/$name"
      printf 'worktree_%s=%s\n' "$name" "$umbrella_dir/repos/$name"
    done
  } > "$meta"
  chmod 0600 "$meta" 2>/dev/null || true

  ok=1
  trap - EXIT HUP INT TERM

  echo "created umbrella $id"
  echo "  repos: $repos_field"
  echo "  lab:   umbrellas/$id/  (cd there and drive your coding agent)"
  echo "  design: umbrellas/$id/DESIGN.md"
}

cmd_teardown() {
  local id="" force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) err "unknown flag: $1"; exit 2 ;;
      *) if [ -z "$id" ]; then id=$1; shift; else err "unexpected argument: $1"; exit 2; fi ;;
    esac
  done
  if [ -z "$id" ]; then
    err "usage: fm-umbrella.sh teardown <umbrella-id> [--force]"
    exit 2
  fi
  if ! umbrella_id_valid "$id"; then
    err "invalid umbrella id: $id"
    exit 2
  fi

  local umbrella_dir="$UMBRELLAS/$id"
  local meta="$umbrella_dir/umbrella.meta"
  if [ ! -f "$meta" ]; then
    err "no umbrella metadata at umbrellas/$id/umbrella.meta"
    exit 1
  fi
  if [ "$(umbrella_meta_get "$meta" kind || true)" != umbrella ]; then
    err "umbrellas/$id is not an umbrella (kind mismatch)"
    exit 1
  fi

  # Completion gate: DESIGN.md must exist and be non-empty, unless forced.
  if [ "$force" != 1 ]; then
    if [ ! -s "$umbrella_dir/DESIGN.md" ]; then
      err "DESIGN.md is missing or empty; capture the design first or pass --force"
      exit 1
    fi
  fi

  local repos_field name
  repos_field=$(umbrella_meta_get "$meta" repos || true)
  local IFS_SAVE=$IFS
  IFS=','
  # shellcheck disable=SC2206
  local names=($repos_field)
  IFS=$IFS_SAVE

  local failures=0
  for name in "${names[@]}"; do
    [ -n "$name" ] || continue
    local wt clone
    wt=$(umbrella_meta_get "$meta" "worktree_$name" || true)
    clone=$(umbrella_meta_get "$meta" "clone_$name" || true)
    [ -n "$wt" ] || continue
    if [ -d "$wt" ]; then
      local status
      status=$(git -C "$wt" status --short 2>/dev/null || true)
      if [ -n "$status" ]; then
        echo "discarding scratch changes in $name:"
        printf '%s\n' "$status" | sed 's/^/    /'
      fi
    fi
    if [ -n "$clone" ] && git -C "$clone" rev-parse --git-dir >/dev/null 2>&1; then
      if ! git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1; then
        rm -rf -- "$wt" 2>/dev/null || true
        git -C "$clone" worktree prune >/dev/null 2>&1 || true
      fi
    else
      rm -rf -- "$wt" 2>/dev/null || true
    fi
    if [ -d "$wt" ]; then
      err "could not fully remove worktree for '$name' at $wt"
      failures=$((failures + 1))
    fi
  done

  if [ "$failures" -ne 0 ]; then
    err "left umbrella metadata in place because $failures worktree(s) did not return cleanly"
    exit 1
  fi

  rm -rf -- "$umbrella_dir/repos" 2>/dev/null || true
  rm -f -- "$meta" "$umbrella_dir/AGENTS.md" 2>/dev/null || true

  echo "tore down umbrella $id"
  if [ -f "$umbrella_dir/DESIGN.md" ]; then
    echo "  kept: umbrellas/$id/DESIGN.md"
  fi
}

cmd_list() {
  local found=0 meta id repos design
  if [ -d "$UMBRELLAS" ]; then
    for meta in "$UMBRELLAS"/*/umbrella.meta; do
      [ -f "$meta" ] || continue
      [ "$(umbrella_meta_get "$meta" kind || true)" = umbrella ] || continue
      found=1
      id=$(umbrella_meta_get "$meta" umbrella_id || true)
      repos=$(umbrella_meta_get "$meta" repos || true)
      design="$UMBRELLAS/$id/DESIGN.md"
      local dstate="no DESIGN.md"
      [ -s "$design" ] && dstate="DESIGN.md ready"
      printf '%s  repos=%s  (%s)\n' "$id" "$repos" "$dstate"
    done
  fi
  [ "$found" = 1 ] || echo "no umbrellas"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  create) shift; cmd_create "$@" ;;
  teardown) shift; cmd_teardown "$@" ;;
  list) shift; cmd_list "$@" ;;
  *) err "unknown command: $1"; usage; exit 2 ;;
esac
