#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a fast-forward. A dirty default-branch checkout is
# allowed only when every dirty path is resolved: tracked working-tree and staged
# content must match the incoming blob bytes and tree mode, while
# tracked-to-untracked conversions and untracked files or directories must be
# ignored by the target head's .gitignore rules under the project's
# core.ignoreCase semantics; info/exclude and global excludes do not count.
# An ignored directory is allowed only when the target head tracks nothing under
# its prefix. Every unresolved path is diagnosed before advancing. Proven ignored
# files are retained byte-for-byte; proven ignored directories remain directories
# without walking or hashing their contents. Every previously dirty path is then
# verified clean. A preservation or cleanliness failure after the fast-forward is
# reported without attempting rollback. Diverged branches still refuse and
# require the crewmate to rebase. See AGENTS.md prime directives, project
# management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }

TARGET_VIEW_ROOT=
TARGET_VIEW_TREE=
TARGET_VIEW_INDEX=
TARGET_VIEW_GIT_DIR=
TARGET_VIEW_PATHS=
TARGET_GIT_DIR=
TARGET_IGNORE_CASE=false
PRESERVE_TEMP_ROOT=
MOVED_PATHS=()
MOVED_RESTORED=()

cleanup_target_view() {
  if [ -n "$TARGET_VIEW_ROOT" ] && [ -d "$TARGET_VIEW_ROOT" ]; then
    rm -rf -- "$TARGET_VIEW_ROOT"
  fi
}

restore_moved_paths() {
  local i path saved destination parent failed=0
  for ((i = 0; i < ${#MOVED_PATHS[@]}; i++)); do
    [ "${MOVED_RESTORED[$i]}" -eq 0 ] || continue
    path=${MOVED_PATHS[$i]}
    saved="$PRESERVE_TEMP_ROOT/files/$path"
    destination="$PROJ/$path"
    if [ ! -e "$saved" ] && [ ! -L "$saved" ]; then
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        MOVED_RESTORED[i]=1
        continue
      fi
      printf 'error: preserved path %q is missing from both the checkout and %q\n' \
        "$path" "$saved" >&2
      failed=1
      continue
    fi
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      printf 'error: cannot restore preserved path %q because the destination now exists; saved copy remains at %q\n' \
        "$path" "$saved" >&2
      failed=1
      continue
    fi
    parent=${destination%/*}
    if ! mkdir -p "$parent" || ! mv -- "$saved" "$destination"; then
      printf 'error: could not restore preserved path %q; saved copy remains at %q\n' \
        "$path" "$saved" >&2
      failed=1
      continue
    fi
    MOVED_RESTORED[i]=1
  done
  [ "$failed" -eq 0 ]
}

cleanup_merge_temps() {
  local rc=$? restore_failed=0
  if ! restore_moved_paths; then
    restore_failed=1
  fi
  cleanup_target_view
  if [ -n "$PRESERVE_TEMP_ROOT" ] && [ -d "$PRESERVE_TEMP_ROOT" ]; then
    if [ "$restore_failed" -eq 0 ]; then
      rm -rf -- "$PRESERVE_TEMP_ROOT"
    else
      printf 'error: preserved files require manual recovery from %q\n' \
        "$PRESERVE_TEMP_ROOT" >&2
    fi
  fi
  return "$rc"
}
trap cleanup_merge_temps EXIT

init_target_view() {
  local empty_template path
  TARGET_VIEW_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-local.XXXXXX") || return 1
  TARGET_VIEW_TREE="$TARGET_VIEW_ROOT/tree"
  TARGET_VIEW_INDEX="$TARGET_VIEW_ROOT/index"
  empty_template="$TARGET_VIEW_ROOT/empty-template"
  TARGET_VIEW_PATHS="$TARGET_VIEW_ROOT/tree-paths"
  TARGET_GIT_DIR=$(git -C "$PROJ" rev-parse --absolute-git-dir) || return 1
  TARGET_IGNORE_CASE=$(
    git -C "$PROJ" config --type=bool --default=false --get core.ignoreCase
  ) || return 1
  mkdir -p "$TARGET_VIEW_TREE" "$empty_template" || return 1
  git -c init.defaultBranch=fm-target-view init -q \
    --template="$empty_template" "$TARGET_VIEW_TREE" || return 1
  TARGET_VIEW_GIT_DIR="$TARGET_VIEW_TREE/.git"
  GIT_INDEX_FILE="$TARGET_VIEW_INDEX" git -C "$PROJ" read-tree "$BRANCH" || return 1
  git -C "$PROJ" ls-tree -r -z --name-only "$BRANCH" >"$TARGET_VIEW_PATHS" || return 1

  while IFS= read -r -d '' path; do
    case "$path" in
      .gitignore|*/.gitignore)
        GIT_DIR="$TARGET_GIT_DIR" \
        GIT_WORK_TREE="$TARGET_VIEW_TREE" \
        GIT_INDEX_FILE="$TARGET_VIEW_INDEX" \
        GIT_LITERAL_PATHSPECS=1 \
          git -C "$TARGET_VIEW_TREE" checkout-index -- "$path" || return 1
        ;;
    esac
  done <"$TARGET_VIEW_PATHS"
}

branch_ignores_path() {
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_DIR="$TARGET_VIEW_GIT_DIR" \
  GIT_WORK_TREE="$TARGET_VIEW_TREE" \
  GIT_INDEX_FILE="$TARGET_VIEW_INDEX" \
    git -c core.excludesFile=/dev/null \
      -c core.ignoreCase="$TARGET_IGNORE_CASE" \
      -C "$TARGET_VIEW_TREE" check-ignore --quiet -- "$1"
}

branch_ignores_directory_path() {
  local path
  path=${1%/}/
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_DIR="$TARGET_VIEW_GIT_DIR" \
  GIT_WORK_TREE="$TARGET_VIEW_TREE" \
  GIT_INDEX_FILE="$TARGET_VIEW_INDEX" \
    git -c core.excludesFile=/dev/null \
      -c core.ignoreCase="$TARGET_IGNORE_CASE" \
      -C "$TARGET_VIEW_TREE" check-ignore --no-index --quiet -- "$path"
}

branch_blob_metadata() {
  GIT_LITERAL_PATHSPECS=1 git -C "$PROJ" ls-tree "$BRANCH" -- "$1" \
    | awk 'NR == 1 { print $1, $2, $3 }'
}

index_blob_metadata() {
  GIT_LITERAL_PATHSPECS=1 git -C "$PROJ" ls-files --stage -- "$1" \
    | awk '$3 == 0 { print $1, $2; exit }'
}

working_tree_mode() {
  local mode path=$1
  mode=$(
    GIT_LITERAL_PATHSPECS=1 git -c core.fileMode=true \
      -C "$PROJ" diff-files --raw --no-abbrev -- "$path" \
      | awk 'NR == 1 { sub(/^:/, "", $1); print $2 }'
  ) || return 1
  if [ -z "$mode" ]; then
    mode=$(index_blob_metadata "$path") || return 1
    mode=${mode%% *}
  fi
  [ -n "$mode" ] && [ "$mode" != "000000" ] || return 1
  printf '%s\n' "$mode"
}

staged_state_matches_worktree() {
  local current_mode current_oid index_meta index_mode index_oid path=$1
  index_meta=$(index_blob_metadata "$path") || return 1
  if [ ! -e "$PROJ/$path" ] && [ ! -L "$PROJ/$path" ]; then
    [ -z "$index_meta" ]
    return
  fi
  [ -n "$index_meta" ] || return 1
  index_mode=${index_meta%% *}
  index_oid=${index_meta##* }
  current_oid=$(git -C "$PROJ" hash-object -- "$path" 2>/dev/null) || return 1
  current_mode=$(working_tree_mode "$path") || return 1
  [ "$index_oid" = "$current_oid" ] && [ "$index_mode" = "$current_mode" ]
}

branch_tree_uses_directory_prefix() {
  local matches path=$1 pathspec prefix
  prefix=${path%/}
  pathspec=":(literal)$prefix"
  if [ "$TARGET_IGNORE_CASE" = true ]; then
    pathspec=":(icase,literal)$prefix"
  fi
  matches=$(
    GIT_INDEX_FILE="$TARGET_VIEW_INDEX" \
      git -C "$PROJ" ls-files -- "$pathspec"
  ) || return 2
  [ -n "$matches" ]
}

DIRTY_PATHS=()
DIRTY_STATES=()
while IFS= read -r -d '' record; do
  state=${record:0:2}
  path=${record:3}
  DIRTY_PATHS+=("$path")
  DIRTY_STATES+=("$state")
  case "$state" in
    *R*|*C*)
      if IFS= read -r -d '' source_path; then
        DIRTY_PATHS+=("$source_path")
        DIRTY_STATES+=("rename-source")
      fi
      ;;
  esac
done < <(
  git -C "$PROJ" status --porcelain=v1 -z \
    --untracked-files=normal --ignored=matching
)

UNRESOLVED_PATHS=()
UNRESOLVED_REASONS=()
RESOLVED_PATHS=()
RESOLVED_ACTIONS=()
RESOLVED_MODES=()
RESOLVED_OIDS=()
PRESERVE_PATHS=()
PRESERVE_KINDS=()
PRESERVE_OIDS=()

add_unresolved() {
  UNRESOLVED_PATHS+=("$1")
  UNRESOLVED_REASONS+=("$2")
}

expand_unignored_untracked_directories() {
  local i path state record records_path ignore_directory_rc
  local -a expanded_paths=() expanded_states=()
  for ((i = 0; i < ${#DIRTY_PATHS[@]}; i++)); do
    path=${DIRTY_PATHS[$i]}
    state=${DIRTY_STATES[$i]}
    if [ "$state" != "??" ] || [ ! -d "$PROJ/$path" ] || [ -L "$PROJ/$path" ]; then
      expanded_paths+=("$path")
      expanded_states+=("$state")
      continue
    fi

    set +e
    branch_ignores_directory_path "$path"
    ignore_directory_rc=$?
    set -e
    case "$ignore_directory_rc" in
      0)
        # The later collision proof covers this entire prefix, so do not walk it.
        expanded_paths+=("$path")
        expanded_states+=("$state")
        ;;
      1)
        # A whole-directory proof is unavailable.  Preserve the established
        # regular-file behavior by enumerating this one prefix for target-ignored
        # files, rather than recursively walking every untracked directory.
        records_path="$TARGET_VIEW_ROOT/untracked-$i"
        if ! git -C "$PROJ" status --porcelain=v1 -z --untracked-files=all \
          -- ":(literal)$path" >"$records_path"; then
          return 1
        fi
        while IFS= read -r -d '' record; do
          expanded_paths+=("${record:3}")
          expanded_states+=("${record:0:2}")
        done <"$records_path"
        ;;
      *)
        return 1
        ;;
    esac
  done
  DIRTY_PATHS=("${expanded_paths[@]}")
  DIRTY_STATES=("${expanded_states[@]}")
}

remember_preserved_path() {
  local path=$1 oid
  if oid=$(git -C "$PROJ" hash-object -- "$path" 2>/dev/null); then
    PRESERVE_PATHS+=("$path")
    PRESERVE_KINDS+=("blob")
    PRESERVE_OIDS+=("$oid")
  elif [ ! -e "$PROJ/$path" ] && [ ! -L "$PROJ/$path" ]; then
    PRESERVE_PATHS+=("$path")
    PRESERVE_KINDS+=("absent")
    PRESERVE_OIDS+=("")
  else
    return 1
  fi
}

remember_preserved_directory() {
  local path=$1
  if [ -d "$PROJ/$path" ] && [ ! -L "$PROJ/$path" ]; then
    PRESERVE_PATHS+=("$path")
    PRESERVE_KINDS+=("directory")
    PRESERVE_OIDS+=("")
    return 0
  fi
  return 1
}

move_preserved_path_out_of_merge() {
  local path=$1 saved parent index
  if [ ! -e "$PROJ/$path" ] && [ ! -L "$PROJ/$path" ]; then
    return 0
  fi
  if [ -z "$PRESERVE_TEMP_ROOT" ]; then
    PRESERVE_TEMP_ROOT=$(mktemp -d "$TARGET_GIT_DIR/fm-merge-local-preserve.XXXXXX") \
      || return 1
  fi
  saved="$PRESERVE_TEMP_ROOT/files/$path"
  parent=${saved%/*}
  mkdir -p "$parent" || return 1
  index=${#MOVED_PATHS[@]}
  MOVED_PATHS+=("$path")
  MOVED_RESTORED+=("0")
  if ! mv -- "$PROJ/$path" "$saved"; then
    if [ -e "$PROJ/$path" ] || [ -L "$PROJ/$path" ]; then
      MOVED_RESTORED[index]=1
    fi
    return 1
  fi
}

if [ "${#DIRTY_PATHS[@]}" -gt 0 ]; then
  if ! init_target_view; then
    echo "error: could not construct the $BRANCH ignore view; refusing to merge a dirty checkout" >&2
    exit 1
  fi
  if ! expand_unignored_untracked_directories; then
    echo "error: could not classify untracked directories against $BRANCH; refusing to merge a dirty checkout" >&2
    exit 1
  fi

  for ((i = 0; i < ${#DIRTY_PATHS[@]}; i++)); do
    path=${DIRTY_PATHS[$i]}
    state=${DIRTY_STATES[$i]}

    case "$state" in
      rename-source|*R*|*C*)
        add_unresolved "$path" "rename or copy state '$state' is not a supported resolved form"
        continue
        ;;
    esac

    if [ -d "$PROJ/$path" ] && [ ! -L "$PROJ/$path" ]; then
      set +e
      branch_ignores_directory_path "$path"
      ignore_directory_rc=$?
      set -e
      case "$ignore_directory_rc" in
        0)
          if [ "$state" != "??" ] && [ "$state" != "!!" ] \
            && [ "${state:0:1}" != " " ]; then
            add_unresolved "$path" "staged state cannot be preserved when the working-tree path is a directory"
            continue
          fi
          set +e
          branch_tree_uses_directory_prefix "$path"
          prefix_collision_rc=$?
          set -e
          case "$prefix_collision_rc" in
            0)
              add_unresolved "$path" "ignored directory has an incoming tracked path under its prefix"
              continue
              ;;
            1)
              ;;
            *)
              add_unresolved "$path" "could not inspect the branch head for paths under the ignored directory prefix"
              continue
              ;;
          esac
          if ! remember_preserved_directory "$path"; then
            add_unresolved "$path" "ignored directory disappeared during merge preparation"
            continue
          fi
          RESOLVED_PATHS+=("$path")
          RESOLVED_MODES+=("")
          RESOLVED_OIDS+=("")
          if [ "$state" = "??" ] || [ "$state" = "!!" ]; then
            RESOLVED_ACTIONS+=("keep-untracked")
          else
            RESOLVED_ACTIONS+=("remove-index-preserve-directory")
          fi
          continue
          ;;
        1)
          ;;
        *)
          add_unresolved "$path" "could not evaluate branch-head ignore rules for the directory"
          continue
          ;;
      esac
    fi

    set +e
    branch_ignores_path "$path"
    ignore_rc=$?
    set -e
    case "$ignore_rc" in
      0)
        if [ "$state" != "??" ] && [ "$state" != "!!" ] \
          && [ "${state:0:1}" != " " ] \
          && ! staged_state_matches_worktree "$path"; then
          add_unresolved "$path" "staged content or mode does not match the working-tree copy preserved by the branch-head ignore rule"
          continue
        fi
        RESOLVED_PATHS+=("$path")
        RESOLVED_MODES+=("")
        RESOLVED_OIDS+=("")
        if [ "$state" = "??" ] || [ "$state" = "!!" ]; then
          RESOLVED_ACTIONS+=("verify-ignored-file")
        else
          RESOLVED_ACTIONS+=("verify-ignored-file-remove-index")
        fi
        continue
        ;;
      1)
        ;;
      *)
        add_unresolved "$path" "could not evaluate branch-head ignore rules"
        continue
        ;;
    esac

    if [ "$state" = "??" ] || [ "$state" = "!!" ]; then
      add_unresolved "$path" "untracked path is not ignored at the branch head"
      continue
    fi
    case "$state" in
      *U*|*D*|AA)
        add_unresolved "$path" "status '$state' is not modified or added tracked content"
        continue
        ;;
      *M*|*A*)
        ;;
      *)
        add_unresolved "$path" "status '$state' is not a supported resolved form"
        continue
        ;;
    esac

    blob_meta=$(branch_blob_metadata "$path")
    if [ -z "$blob_meta" ]; then
      add_unresolved "$path" "the branch head has no entry for the modified or added path"
      continue
    fi
    target_mode=${blob_meta%% *}
    blob_meta=${blob_meta#* }
    target_type=${blob_meta%% *}
    target_oid=${blob_meta##* }
    if [ "$target_type" != "blob" ]; then
      add_unresolved "$path" "the branch-head entry is '$target_type', not a file blob"
      continue
    fi
    if [ "${state:0:1}" != " " ]; then
      index_meta=$(index_blob_metadata "$path")
      if [ -z "$index_meta" ]; then
        add_unresolved "$path" "staged content has no ordinary index entry"
        continue
      fi
      index_mode=${index_meta%% *}
      index_oid=${index_meta##* }
      if [ "$index_oid" != "$target_oid" ]; then
        add_unresolved "$path" "staged content does not match the branch-head blob"
        continue
      fi
      if [ "$index_mode" != "$target_mode" ]; then
        add_unresolved "$path" "staged mode $index_mode does not match branch-head mode $target_mode"
        continue
      fi
    fi
    RESOLVED_PATHS+=("$path")
    RESOLVED_ACTIONS+=("verify-branch-blob")
    RESOLVED_MODES+=("$target_mode")
    RESOLVED_OIDS+=("$target_oid")
  done
fi

if [ "${#UNRESOLVED_PATHS[@]}" -gt 0 ]; then
  echo "error: $PROJ has dirty paths not resolved by $BRANCH; refusing to merge:" >&2
  for ((i = 0; i < ${#UNRESOLVED_PATHS[@]}; i++)); do
    printf '  - %q: %s\n' "${UNRESOLVED_PATHS[$i]}" "${UNRESOLVED_REASONS[$i]}" >&2
  done
  exit 1
fi

# All dirty paths have now passed their cheap structural checks.  Hash only the
# remaining file candidates, after every ignored-directory collision and every
# unsupported status has already failed closed.
for ((i = 0; i < ${#RESOLVED_PATHS[@]}; i++)); do
  path=${RESOLVED_PATHS[$i]}
  case "${RESOLVED_ACTIONS[$i]}" in
    verify-ignored-file|verify-ignored-file-remove-index)
      if ! remember_preserved_path "$path"; then
        add_unresolved "$path" "ignored path is neither absent nor hashable as a file"
        continue
      fi
      case "${RESOLVED_ACTIONS[$i]}" in
        verify-ignored-file)
          RESOLVED_ACTIONS[i]="keep-untracked"
          ;;
        verify-ignored-file-remove-index)
          RESOLVED_ACTIONS[i]="remove-index"
          ;;
      esac
      ;;
    verify-branch-blob)
      if ! current_oid=$(git -C "$PROJ" hash-object -- "$path" 2>/dev/null); then
        add_unresolved "$path" "working-tree content cannot be hashed as a file"
        continue
      fi
      if [ "$current_oid" != "${RESOLVED_OIDS[$i]}" ]; then
        add_unresolved "$path" "working-tree content does not match the branch-head blob"
        continue
      fi
      if ! current_mode=$(working_tree_mode "$path"); then
        add_unresolved "$path" "working-tree mode cannot be determined"
        continue
      fi
      if [ "$current_mode" != "${RESOLVED_MODES[$i]}" ]; then
        add_unresolved "$path" "working-tree mode $current_mode does not match branch-head mode ${RESOLVED_MODES[$i]}"
        continue
      fi
      RESOLVED_ACTIONS[i]="set-index"
      ;;
  esac
done

if [ "${#UNRESOLVED_PATHS[@]}" -gt 0 ]; then
  echo "error: $PROJ has dirty paths not resolved by $BRANCH; refusing to merge:" >&2
  for ((i = 0; i < ${#UNRESOLVED_PATHS[@]}; i++)); do
    printf '  - %q: %s\n' "${UNRESOLVED_PATHS[$i]}" "${UNRESOLVED_REASONS[$i]}" >&2
  done
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

for ((i = 0; i < ${#RESOLVED_PATHS[@]}; i++)); do
  path=${RESOLVED_PATHS[$i]}
  case "${RESOLVED_ACTIONS[$i]}" in
    set-index)
      git -C "$PROJ" update-index --add \
        --cacheinfo "${RESOLVED_MODES[$i]},${RESOLVED_OIDS[$i]},$path"
      ;;
    remove-index)
      git -C "$PROJ" update-index --force-remove -- "$path"
      move_preserved_path_out_of_merge "$path"
      ;;
    remove-index-preserve-directory)
      git -C "$PROJ" update-index --force-remove -- "$path"
      ;;
    keep-untracked)
      ;;
  esac
done

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
if ! restore_moved_paths; then
  printf 'error: fast-forward completed, but preserved files require manual recovery from %q\n' \
    "$PRESERVE_TEMP_ROOT" >&2
  exit 1
fi

for ((i = 0; i < ${#PRESERVE_PATHS[@]}; i++)); do
  path=${PRESERVE_PATHS[$i]}
  if [ "${PRESERVE_KINDS[$i]}" = "absent" ]; then
    if [ -e "$PROJ/$path" ] || [ -L "$PROJ/$path" ]; then
      printf 'error: fast-forward completed, but ignored path %q was absent before the merge and now exists\n' "$path" >&2
      exit 1
    fi
    continue
  fi
  if [ "${PRESERVE_KINDS[$i]}" = "directory" ]; then
    if [ ! -d "$PROJ/$path" ] || [ -L "$PROJ/$path" ]; then
      printf 'error: fast-forward completed, but ignored directory %q is now absent or no longer a directory\n' \
        "$path" >&2
      exit 1
    fi
    continue
  fi
  if ! preserved_oid=$(git -C "$PROJ" hash-object -- "$path" 2>/dev/null); then
    printf 'error: fast-forward completed, but ignored path %q was blob %s before the merge and is now absent or unreadable\n' \
      "$path" "${PRESERVE_OIDS[$i]}" >&2
    exit 1
  fi
  if [ "$preserved_oid" != "${PRESERVE_OIDS[$i]}" ]; then
    printf 'error: fast-forward completed, but ignored path %q changed from blob %s to blob %s\n' \
      "$path" "${PRESERVE_OIDS[$i]}" "$preserved_oid" >&2
    exit 1
  fi
done

if [ "${#DIRTY_PATHS[@]}" -gt 0 ]; then
  POST_PATHS=()
  for path in "${DIRTY_PATHS[@]}"; do
    POST_PATHS+=(":(literal)$path")
  done
  post_status=$(git -C "$PROJ" status --porcelain=v1 --untracked-files=normal -- "${POST_PATHS[@]}")
  if [ -n "$post_status" ]; then
    echo "error: fast-forward completed, but previously dirty resolved paths are not clean:" >&2
    printf '%s\n' "$post_status" >&2
    exit 1
  fi
fi

echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
