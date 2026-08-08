#!/usr/bin/env bash
# Shared "proj" worktree-provider primitives: acquiring and removing task
# worktrees and secondmate homes, and resolving a registered project's name to
# its proj-managed location on disk.
#
# proj (host-level tooling at /usr/bin/proj; no public release to pin here -
# see docs/architecture.md) pools nothing: PROJ_ROOT/projects/<name>
# holds one non-worked-in `.repo` plus one or more `00-*` template worktrees
# (read-only to firstmate; `proj sync` refreshes them and is captain-run only,
# never automatic), and `proj new`/`proj rm` reflink-copy/remove sibling task
# worktrees on demand. Every proj worktree - template or task - checks out a
# real named branch (never detached HEAD), unlike the treehouse worktrees this
# replaces; the primary-vs-worktree guards firstmate already has (git-dir vs
# git-common-dir, and the .fm-secondmate-home marker) never relied on detached
# HEAD to tell them apart, so they need no changes for that.
#
# `proj new`/`proj rm` route their whole implementation through `main >&2`
# (see /usr/bin/proj-new, /usr/bin/proj-rm), so ALL banners/trace/errors land on
# stderr; `proj new` alone prints the created worktree's path, and only that
# path, to stdout on success. `proj new` also requires exactly one `00-*`
# template in the project directory (it picks the template via
# `find . -maxdepth 1 -name '00-*' | fzf -1 -0`, which launches an interactive
# picker on 2+ matches) - fm_proj_template_dir asserts exactly one and fails
# loudly rather than ever risking that hang.
#
# No side effects on source. set -u / set -e safe.

# fm_proj_root: PROJ_ROOT, or proj's own /mnt/work default when unset.
fm_proj_root() {
  printf '%s\n' "${PROJ_ROOT:-/mnt/work}"
}

# fm_proj_projects_root: the directory proj keeps every project under.
fm_proj_projects_root() {
  printf '%s\n' "$(fm_proj_root)/projects"
}

# fm_proj_project_dir <name>: the project's root directory (not yet checked
# for existence - callers that need existence use fm_proj_template_dir).
fm_proj_project_dir() {
  printf '%s\n' "$(fm_proj_projects_root)/$1"
}

# fm_proj_template_dir_at <project-dir>: <project-dir>'s single `00-*` template
# worktree. Silent, plain failure (return 1, no output) when <project-dir> is
# absent or holds no template at all - the ordinary "not proj-managed (yet)"
# case every caller here treats as a fallback signal, not an error. A LOUD
# failure (stderr message, return 1) when 2+ templates exist: proj new's own
# fzf picker would hang non-interactively on that, so this refuses before ever
# reaching it.
fm_proj_template_dir_at() {
  local project_dir=$1 d templates=()
  [ -d "$project_dir" ] || return 1
  for d in "$project_dir"/00-*; do
    [ -d "$d" ] || continue
    templates+=("$d")
  done
  case "${#templates[@]}" in
    1) printf '%s\n' "${templates[0]}" ;;
    0) return 1 ;;
    *)
      echo "error: proj project at $project_dir has ${#templates[@]} template worktrees (00-*); proj new requires exactly one (2+ would launch an interactive picker) - remove the extras" >&2
      return 1
      ;;
  esac
}

# fm_proj_template_dir <name>: fm_proj_template_dir_at for the project named
# <name> (i.e. under $(fm_proj_root)/projects/<name>).
fm_proj_template_dir() {
  fm_proj_template_dir_at "$(fm_proj_project_dir "$1")"
}

# fm_proj_is_managed <name>: true when the project has exactly one 00-*
# template. Silent either way; a caller that wants the loud multi-template
# diagnostic should call fm_proj_template_dir directly instead.
fm_proj_is_managed() {
  fm_proj_template_dir "$1" >/dev/null 2>/dev/null
}

# fm_proj_project_name_for_dir <path>: the proj project name that owns <path>,
# when <path> is a project's 00-* template directory (basename(dirname(path))).
# Falls back to plain basename(path) for every other shape - a legacy clone, a
# task worktree, or any other directory - which is exactly today's behavior
# for those inputs, so this is a safe drop-in for a bare `basename` call.
fm_proj_project_name_for_dir() {
  local path=$1 root
  root=$(fm_proj_project_root_for_dir "$path")
  if [ "$root" != "$path" ]; then
    basename "$root"
  else
    basename "$path"
  fi
}

# fm_proj_project_root_for_dir <path>: when <path> is a project's 00-*
# template directory, its project root (dirname(path)); otherwise <path>
# itself, unchanged. Used to go from an already-resolved directory (as
# fm-spawn.sh already has in PROJ_ABS) straight to the directory `proj new`
# must run from, with no re-derivation through a name or PROJ_ROOT guess.
fm_proj_project_root_for_dir() {
  local path=$1 base parent
  base=$(basename "$path")
  case "$base" in
    00-*)
      parent=$(dirname "$path")
      if [ "$(dirname "$parent")" = "$(fm_proj_projects_root)" ]; then
        printf '%s\n' "$parent"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$path"
}

# fm_proj_resolve_project_source <name> <legacy-dir>: prefer the project's proj
# template when it is proj-managed; otherwise fall back to <legacy-dir>
# unchanged. Never migrates anything - purely a read of whichever location is
# currently authoritative for <name>.
fm_proj_resolve_project_source() {
  local name=$1 legacy=$2 template
  if template=$(fm_proj_template_dir "$name" 2>/dev/null); then
    printf '%s\n' "$template"
  else
    printf '%s\n' "$legacy"
  fi
}

# fm_proj_self_project_name <fm-root>: the proj project name firstmate's own
# repo is expected to be imported under (see docs/architecture.md and
# secondmate-provisioning) - derived from the checkout's own directory name so
# a renamed clone still resolves consistently.
fm_proj_self_project_name() {
  basename "$1"
}

# fm_proj_new_worktree_in <project-dir> <worktree-name>: create a fresh task
# worktree via `proj new`, run from <project-dir> directly (no re-derivation
# through a name or PROJ_ROOT guess - the caller passes the exact directory,
# e.g. via fm_proj_project_root_for_dir or fm_proj_project_dir), and print its
# path on success. <project-dir> must already be a proj project with exactly
# one 00-* template (see fm_proj_template_dir_at); this is not auto-migration;
# a project that has not been `proj import`-ed or `proj init`-ed gets a clear,
# actionable error.
fm_proj_new_worktree_in() {
  local project_dir=$1 worktree=$2
  if ! fm_proj_template_dir_at "$project_dir" >/dev/null; then
    [ -d "$project_dir" ] && return 1
    echo "error: '$project_dir' is not a proj project (no such directory); run 'proj import --local <path> --name <name> --branch <default-branch>' (or 'proj init') for it first" >&2
    return 1
  fi
  ( cd "$project_dir" && proj new "$worktree" )
}

# fm_proj_new_worktree <project-name> <worktree-name>: fm_proj_new_worktree_in
# for the project named <name> (i.e. under $(fm_proj_root)/projects/<name>).
fm_proj_new_worktree() {
  fm_proj_new_worktree_in "$(fm_proj_project_dir "$1")" "$2"
}

# fm_proj_detach_worktree <dir>: detach <dir> from whatever branch `proj new`
# just checked it out on and delete that now-unreferenced branch, landing the
# worktree at the same commit with no branch checked out. `proj new` always
# checks out a real named branch, never a detached HEAD (bin/proj-new), but a
# firstmate secondmate home needs the detached-HEAD shape bin/fm-ff-lib.sh's
# self-update fast-forward assumes (see that file's header); a no-op if the
# worktree is already detached. Only for a worktree that will serve as a
# firstmate home, never a task worktree meant to carry real branch work.
fm_proj_detach_worktree() {
  local dir=$1 branch
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || return 0
  git -C "$dir" checkout --detach HEAD >/dev/null 2>&1 || return 1
  git -C "$dir" branch -D "$branch" >/dev/null 2>&1 || true
}

# fm_proj_remove_worktree <project-name> <worktree-name> [--force]: remove a
# task worktree or secondmate home via `proj rm`. Location-independent (proj
# rm's "<project>/<name>" form resolves without depending on cwd), so callers
# never need to cd anywhere first. `proj rm` has no stdout output at all
# (see script header); success/failure is exit status only. Omitting --force
# lets git's own worktree-remove dirty-tree refusal stand as the backstop.
fm_proj_remove_worktree() {
  local name=$1 worktree=$2 force=${3:-}
  if [ -n "$force" ]; then
    proj rm "$name/$worktree" "$force"
  else
    proj rm "$name/$worktree"
  fi
}
