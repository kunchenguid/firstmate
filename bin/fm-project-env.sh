#!/usr/bin/env bash
# Materialize a project's LOCAL, gitignored env files into a working copy.
#
# The problem this solves: git never copies ignored files into a new worktree,
# so every fresh worktree starts without .env.local and whatever populated the
# older ones is not reproducible. This makes that population deterministic from
# one source of truth that lives OUTSIDE every project checkout.
#
# Source of truth (the "store"):
#   $FM_PROJECT_ENV_DIR, else <config>/project-env
# and inside it, one directory per project holding the files at their
# repo-relative paths:
#   <store>/<project>/.env.local
#   <store>/<project>/apps/web/.env.local
# The directory tree IS the manifest; there is no separate config file.
#
# Usage:
#   fm-project-env.sh apply  <project> <target-dir>
#   fm-project-env.sh status [<project>]
#   fm-project-env.sh adopt  [--force] <project> <source-dir> <relative-path>...
#   fm-project-env.sh root
#
# apply COPIES (never symlinks) each stored file into <target-dir> at mode 0600.
# Copying is deliberate: a worktree is disposable and must not be able to mutate
# the fleet's source of truth, and tools that rewrite an env file in place
# (vercel env pull, editors that replace-on-save) would otherwise either follow
# the link and corrupt the store or silently replace it with a real file.
#
# apply never lets a copy become committable. Before writing, it requires git to
# report the path as untracked and ignored in the target; after writing, it
# requires `git status` to still show nothing for that path, and removes the file
# and refuses if it does not. A store file the project does not ignore is
# refused, never copied and never suppressed with assume-unchanged or
# skip-worktree.
#
# Absence is graceful: a project with no stored file is not an error, so spawning
# continues. When the project tracks a .env.example-style template but has no
# stored file, apply says so instead of leaving a worktree that fails at runtime.
#
# Machine-greppable output lines are prefixed PROJECT_ENV:. Exit codes:
#   0 applied cleanly (including a graceful no-op), 1 refusal or failure,
#   2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STORE_ROOT="${FM_PROJECT_ENV_DIR:-$CONFIG/project-env}"

usage() {
  cat >&2 <<'USAGE'
Usage:
  fm-project-env.sh apply  <project> <target-dir>
  fm-project-env.sh status [<project>]
  fm-project-env.sh adopt  [--force] <project> <source-dir> <relative-path>...
  fm-project-env.sh root
USAGE
  exit 2
}

note() { printf 'PROJECT_ENV: %s\n' "$1"; }
warn() { printf 'PROJECT_ENV: %s\n' "$1" >&2; }

# Names a project directory in the store. Rejects separators and traversal so a
# caller-supplied project name can never escape the store root.
project_name_valid() {
  case "${1:-}" in
    ''|.|..) return 1 ;;
    */*) return 1 ;;
    -*) return 1 ;;
    *) return 0 ;;
  esac
}

# Absolute path of an existing directory, or failure.
resolved_dir() {
  [ -d "${1:-}" ] || return 1
  (cd "$1" && pwd -P)
}

is_work_tree() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Repo-relative paths of every regular file in a project's store directory.
# Symlinks are skipped: the store is a plain file tree, and following a link out
# of it would copy something the operator did not put there.
store_files() {  # <store-project-dir>
  local root=$1 f
  find "$root" -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    case "${f##*/}" in .DS_Store) continue ;; esac
    printf '%s\n' "${f#"$root"/}"
  done
}

# Tracked .env template paths, used only to explain an empty store.
tracked_env_templates() {  # <target-dir>
  git -C "$1" ls-files 2>/dev/null | grep -E '(^|/)\.env\.(example|sample|template)$' || true
}

files_differ() {  # <a> <b>
  ! cmp -s -- "$1" "$2"
}

# Copy one stored file into the target, proving at both ends that git will never
# offer it for staging.
apply_one() {  # <store-project-dir> <target-dir> <rel>
  local store=$1 target=$2 rel=$3
  local src="$store/$rel" dst="$target/$rel" status rc

  if git -C "$target" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    warn "refused $rel: the project TRACKS this path; a local env file must be gitignored, and this script will not hide a tracked file"
    return 1
  fi
  if ! git -C "$target" check-ignore -q -- "$rel"; then
    warn "refused $rel: the project does not gitignore this path, so a copy could be staged and pushed; add it to .gitignore first"
    return 1
  fi

  if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
    warn "refused $rel: the working copy already has a symlink or non-regular file there; leaving it untouched"
    return 1
  fi
  if [ -f "$dst" ] && files_differ "$src" "$dst"; then
    note "replaced $rel in $target (it differed from the source of truth at $src)"
  fi

  # Written straight to the proven-ignored destination rather than through a
  # temp file in the worktree: a stray temp name would be untracked AND
  # unignored, which is exactly the dirty state teardown refuses on.
  mkdir -p -- "$(dirname -- "$dst")" || return 1
  # `>` truncates before cat runs, so any failure here leaves a truncated file
  # that looks valid; it is removed rather than left to fail at runtime.
  if ! (umask 077; cat -- "$src" > "$dst") || ! chmod 0600 "$dst"; then
    rm -f -- "$dst"
    warn "refused $rel: could not write it into $target; removed the partial copy"
    return 1
  fi

  # The proof, taken from real repository state rather than assumed from the
  # .gitignore read above: after the write, git must still have nothing to say,
  # and must actually answer - an unanswered query is not a clean answer.
  status=$(git -C "$target" status --porcelain -- "$rel" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$dst"
    warn "refused $rel: git could not report its status in $target (exit $rc), so the never-committed guarantee is unproven; removed it"
    return 1
  fi
  if [ -n "$status" ]; then
    rm -f -- "$dst"
    warn "refused $rel: git reported it as committable after the copy ($status); removed it from $target"
    return 1
  fi
  return 0
}

cmd_apply() {  # <project> <target-dir>
  [ "$#" -eq 2 ] || usage
  local project=$1 target_in=$2
  local target store rel files templates applied=0 failed=0
  project_name_valid "$project" || { warn "refused: invalid project name"; return 1; }

  target=$(resolved_dir "$target_in") || { warn "refused: no such directory $target_in"; return 1; }
  if ! is_work_tree "$target"; then
    warn "refused: $target is not a git working copy, so the never-committed guarantee cannot be proven there"
    return 1
  fi

  store="$STORE_ROOT/$project"
  files=''
  [ -d "$store" ] && files=$(store_files "$store")
  if [ -z "$files" ]; then
    templates=$(tracked_env_templates "$target")
    if [ -n "$templates" ]; then
      note "no local env file stored for $project, but the project ships $(printf '%s' "$templates" | tr '\n' ' ')- this working copy may fail at runtime until one is stored under $store (see docs/configuration.md)"
    fi
    return 0
  fi

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if apply_one "$store" "$target" "$rel"; then
      applied=$((applied + 1))
    else
      failed=$((failed + 1))
    fi
  done <<EOF
$files
EOF

  if [ "$failed" -gt 0 ]; then
    warn "$project: applied $applied local env file(s) to $target, refused $failed"
    return 1
  fi
  note "$project: applied $applied local env file(s) to $target"
  return 0
}

cmd_status() {  # [<project>]
  [ "$#" -le 1 ] || usage
  local project store rel count
  if [ ! -d "$STORE_ROOT" ]; then
    note "no store at $STORE_ROOT"
    return 0
  fi
  if [ "$#" -eq 1 ]; then
    project=$1
    project_name_valid "$project" || { warn "refused: invalid project name"; return 1; }
    store="$STORE_ROOT/$project"
    [ -d "$store" ] || { note "$project: nothing stored (expected $store)"; return 0; }
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      printf 'PROJECT_ENV: %s %s\n' "$project" "$rel"
    done <<EOF
$(store_files "$store")
EOF
    return 0
  fi
  for store in "$STORE_ROOT"/*; do
    [ -d "$store" ] || continue
    count=$(store_files "$store" | grep -c . || true)
    printf 'PROJECT_ENV: %s %s file(s)\n' "${store##*/}" "$count"
  done
  return 0
}

cmd_adopt() {  # [--force] <project> <source-dir> <rel>...
  local force=0 project source_in source rel src dst tmp
  if [ "${1:-}" = --force ]; then
    force=1
    shift
  fi
  [ "$#" -ge 3 ] || usage
  project=$1
  source_in=$2
  shift 2
  project_name_valid "$project" || { warn "refused: invalid project name"; return 1; }
  source=$(resolved_dir "$source_in") || { warn "refused: no such directory $source_in"; return 1; }
  is_work_tree "$source" || { warn "refused: $source is not a git working copy"; return 1; }

  for rel in "$@"; do
    src="$source/$rel"
    dst="$STORE_ROOT/$project/$rel"
    if [ ! -f "$src" ] || [ -L "$src" ]; then
      warn "refused $rel: not a regular file in $source"
      return 1
    fi
    if ! git -C "$source" check-ignore -q -- "$rel"; then
      warn "refused $rel: $source does not gitignore it, so it is not a local-only file"
      return 1
    fi
    if [ -f "$dst" ] && [ "$force" -eq 0 ] && files_differ "$src" "$dst"; then
      warn "refused $rel: the store already holds a different version at $dst; pass --force to replace it"
      return 1
    fi
    mkdir -p -- "$(dirname -- "$dst")" || return 1
    # Written through a temp file and renamed into place: the store is the
    # fleet's source of truth and lives outside every repo, so unlike a
    # worktree it can hold a temp name, and a failed write must never leave a
    # truncated file that every later apply would propagate.
    tmp="$dst.fm-adopt.$$"
    if ! (umask 077; cat -- "$src" > "$tmp") || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dst"; then
      rm -f -- "$tmp"
      warn "refused $rel: could not write it into the store; left $dst unchanged"
      return 1
    fi
    note "stored $project/$rel at $dst"
  done
  return 0
}

[ "$#" -ge 1 ] || usage
SUB=$1
shift
case "$SUB" in
  apply) cmd_apply "$@" ;;
  status) cmd_status "$@" ;;
  adopt) cmd_adopt "$@" ;;
  root) [ "$#" -eq 0 ] || usage; printf '%s\n' "$STORE_ROOT" ;;
  *) usage ;;
esac
