#!/usr/bin/env bash
# Inspect whether one explicit Firstmate home/project is safe input to a future
# shared-object-cache design. This command is detect-only: it never fetches,
# clones, creates a cache or ref, writes an alternate, edits registry/config,
# initializes no-mistakes, scans a development tree, touches state, or performs
# migration/cutover. Its fingerprint identifies the evidence printed by this
# run; it is not cutover authority and must be rechecked by any future tool.
#
# Exit status:
#   0  inspection completed with no blockers found
#   1  inspection completed and found one or more blockers
#   2  invalid arguments or the explicit home cannot be inspected
#
# JSON schema fm-project-layout-preflight.v1 is owned by emit_json below.
# Usage:
#   fm-project-layout-preflight.sh --home <absolute-fm-home> --project <name|absolute-path>
#     [--cache-root <absolute-project-cache-repo>]
#     [--canonical-path <absolute-navigation-only-human-checkout>] [--json]
set -u

unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Prevent `git status` and other read-only porcelain from refreshing the index.
export GIT_OPTIONAL_LOCKS=0

AMBIENT_GIT_ALTERNATES=${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GIT_GRAFT_FILE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
AMBIENT_GIT_CONFIG_COUNT=${GIT_CONFIG_COUNT:-}
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG
case "$AMBIENT_GIT_CONFIG_COUNT" in
  ''|*[!0-9]*) AMBIENT_GIT_CONFIG_COUNT=0 ;;
esac
[ "$AMBIENT_GIT_CONFIG_COUNT" -le 1024 ] || AMBIENT_GIT_CONFIG_COUNT=1024
AMBIENT_CONFIG_INDEX=0
while [ "$AMBIENT_CONFIG_INDEX" -lt "$AMBIENT_GIT_CONFIG_COUNT" ]; do
  unset "GIT_CONFIG_KEY_$AMBIENT_CONFIG_INDEX" "GIT_CONFIG_VALUE_$AMBIENT_CONFIG_INDEX"
  AMBIENT_CONFIG_INDEX=$((AMBIENT_CONFIG_INDEX + 1))
done
unset AMBIENT_CONFIG_INDEX AMBIENT_GIT_CONFIG_COUNT
unset FM_DATA_OVERRIDE FM_ROOT_OVERRIDE

# shellcheck source=bin/fm-project-layout-lib.sh
. "$SCRIPT_DIR/fm-project-layout-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-project-layout-preflight.sh --home <absolute-fm-home> --project <name|absolute-path> [options]

Read-only options:
  --cache-root <path>      Inspect one exact proposed per-project cache repository.
  --canonical-path <path> Inspect one navigation-only human checkout; never use it as Git control state.
  --json                   Emit schema fm-project-layout-preflight.v1 instead of text.
  -h, --help               Show this help.

The command performs no migration or cutover and never creates a missing path.
Exit 0 means no blocker was visible in the supplied local evidence, not that a
future cutover is authorized. Exit 1 means blockers were found. Exit 2 means
the explicit inputs could not be inspected safely.
EOF
}

HOME_ARG=
PROJECT_ARG=
CACHE_ARG=
CANONICAL_ARG=
JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || { echo "error: --home requires a path" >&2; exit 2; }
      HOME_ARG=$2
      shift 2
      ;;
    --home=*) HOME_ARG=${1#--home=}; shift ;;
    --project)
      [ "$#" -ge 2 ] || { echo "error: --project requires a name or path" >&2; exit 2; }
      PROJECT_ARG=$2
      shift 2
      ;;
    --project=*) PROJECT_ARG=${1#--project=}; shift ;;
    --cache-root)
      [ "$#" -ge 2 ] || { echo "error: --cache-root requires a path" >&2; exit 2; }
      CACHE_ARG=$2
      shift 2
      ;;
    --cache-root=*) CACHE_ARG=${1#--cache-root=}; shift ;;
    --canonical-path)
      [ "$#" -ge 2 ] || { echo "error: --canonical-path requires a path" >&2; exit 2; }
      CANONICAL_ARG=$2
      shift 2
      ;;
    --canonical-path=*) CANONICAL_ARG=${1#--canonical-path=}; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ "$#" -eq 0 ] || { echo "error: positional arguments are not accepted" >&2; exit 2; } ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$HOME_ARG" ] || { echo "error: --home is required" >&2; exit 2; }
[ -n "$PROJECT_ARG" ] || { echo "error: --project is required" >&2; exit 2; }
if fmp_has_control "$HOME_ARG$PROJECT_ARG$CACHE_ARG$CANONICAL_ARG"; then
  echo "error: paths and project names must not contain tabs or newlines" >&2
  exit 2
fi
fmp_absolute_path_is_lexically_safe "$HOME_ARG" || {
  echo "error: --home must be a traversal-free absolute path" >&2
  exit 2
}
[ -d "$HOME_ARG" ] || { echo "error: Firstmate home is not a directory: $HOME_ARG" >&2; exit 2; }

BLOCKER_CODES=()
BLOCKER_DETAILS=()
WARNING_CODES=()
WARNING_DETAILS=()

add_blocker() {
  BLOCKER_CODES+=("$1")
  BLOCKER_DETAILS+=("$2")
}

add_warning() {
  WARNING_CODES+=("$1")
  WARNING_DETAILS+=("$2")
}

array_contains() {
  local wanted=$1 value
  shift
  for value in "$@"; do
    [ "$value" = "$wanted" ] && return 0
  done
  return 1
}

paths_match() {
  local left=$1 right=$2 left_physical right_physical
  [ "$left" = "$right" ] && return 0
  left_physical=$(fmp_existing_path_physical "$left" 2>/dev/null) || return 1
  right_physical=$(fmp_existing_path_physical "$right" 2>/dev/null) || return 1
  [ "$left_physical" = "$right_physical" ]
}

HOME_PHYSICAL=$(fmp_existing_path_physical "$HOME_ARG") || {
  echo "error: cannot resolve Firstmate home: $HOME_ARG" >&2
  exit 2
}
if fmp_path_has_symlink_component "$HOME_ARG"; then
  add_blocker home_symlink "Firstmate home has a symlink component"
fi

CURRENT_UID=$(id -u)
HOME_UID=$(fmp_stat_uid "$HOME_PHYSICAL" 2>/dev/null) || HOME_UID=
HOME_MODE=$(fmp_stat_mode "$HOME_PHYSICAL" 2>/dev/null) || HOME_MODE=
[ -n "$HOME_UID" ] || HOME_UID=unknown
[ -n "$HOME_MODE" ] || HOME_MODE=unknown
if [ "$HOME_UID" != "$CURRENT_UID" ]; then
  add_blocker home_owner_mismatch "Firstmate home is not verifiably owned by the current user"
fi
if [ "$HOME_MODE" = unknown ] || fmp_mode_group_or_world_writable "$HOME_MODE"; then
  add_blocker home_writable_by_others "Firstmate home is not verifiably owner-only"
fi

case "$PROJECT_ARG" in
  /*)
    PROJECT_REQUESTED=$PROJECT_ARG
    PROJECT_NAME=$(basename "$PROJECT_ARG")
    ;;
  *)
    PROJECT_REQUESTED="$HOME_PHYSICAL/projects/$PROJECT_ARG"
    PROJECT_NAME=$PROJECT_ARG
    case "$PROJECT_ARG" in
      */*) add_blocker project_not_flat "Relative project names must be one flat projects/ entry" ;;
    esac
    ;;
esac

PROJECT_PHYSICAL=
PROJECT_GIT_DIR=
PROJECT_COMMON_DIR=
PROJECT_UID=unknown
PROJECT_MODE=unknown
REGISTERED=false
REGISTERED_MODE=unknown
REGISTERED_YOLO=unknown
ORIGIN_PRESENT=false
ORIGIN_RAW=
ORIGIN_REDACTED=
ORIGIN_IDENTITY=
DEFAULT_BRANCH=
CURRENT_BRANCH=
OBJECT_FORMAT=unknown
DIRTY=false
OFF_DEFAULT=false
DIVERGED=false
DEFAULT_AHEAD=0
DEFAULT_BEHIND=0
UNPUSHED_COUNT=0
SHALLOW=false
PARTIAL=false
PROMISOR=false
REPLACE_REF_COUNT=0
GRAFTS=false
ALTERNATE=false
NO_MISTAKES_REMOTE=false
WORKTREE_COUNT=0
EXTRA_WORKTREE_COUNT=0
NO_MISTAKES_WORKTREE_COUNT=0
EXTRA_WORKTREES=()
LIVE_TASK_IDS=()
ENDPOINT_COUNT=0
ORCA_COUNT=0
PENDING_REPLY_COUNT=0
SIBLING_BORROWER_COUNT=0
REMOTE_BORROWER_COUNT=0
DUPLICATE_BRANCH_IDS=()

if ! fmp_absolute_path_is_lexically_safe "$PROJECT_REQUESTED"; then
  add_blocker project_path_unsafe "Project path is not a traversal-free absolute path"
elif [ ! -d "$PROJECT_REQUESTED" ]; then
  add_blocker project_missing "Project directory does not exist"
else
  PROJECT_PHYSICAL=$(fmp_existing_path_physical "$PROJECT_REQUESTED") || PROJECT_PHYSICAL=
  if fmp_path_has_symlink_component "$PROJECT_REQUESTED"; then
    add_blocker project_symlink "Project path has a symlink component"
  fi
  if [ -z "$PROJECT_PHYSICAL" ]; then
    add_blocker project_unresolved "Project path could not be resolved to a readable physical directory"
  else
    PROJECTS_PHYSICAL=$(fmp_existing_path_physical "$HOME_PHYSICAL/projects" 2>/dev/null) || PROJECTS_PHYSICAL=
    if [ -z "$PROJECTS_PHYSICAL" ] || ! fmp_path_is_within "$PROJECTS_PHYSICAL" "$PROJECT_PHYSICAL"; then
      add_blocker project_path_escape "Project does not resolve beneath the supplied home's projects directory"
    fi
    PROJECT_UID=$(fmp_stat_uid "$PROJECT_PHYSICAL" 2>/dev/null) || PROJECT_UID=
    PROJECT_MODE=$(fmp_stat_mode "$PROJECT_PHYSICAL" 2>/dev/null) || PROJECT_MODE=
    [ -n "$PROJECT_UID" ] || PROJECT_UID=unknown
    [ -n "$PROJECT_MODE" ] || PROJECT_MODE=unknown
    if [ "$PROJECT_UID" != "$CURRENT_UID" ]; then
      add_blocker project_owner_mismatch "Project is not verifiably owned by the current user"
    fi
    if [ "$PROJECT_MODE" = unknown ] || fmp_mode_group_or_world_writable "$PROJECT_MODE"; then
      add_blocker project_writable_by_others "Project is not verifiably owner-only"
    fi

    PROJECT_TOPLEVEL=$(git -C "$PROJECT_PHYSICAL" rev-parse --show-toplevel 2>/dev/null) || PROJECT_TOPLEVEL=
    if [ -n "$PROJECT_TOPLEVEL" ]; then
      PROJECT_TOPLEVEL=$(fmp_existing_path_physical "$PROJECT_TOPLEVEL" 2>/dev/null) || PROJECT_TOPLEVEL=
    fi
    if ! git -C "$PROJECT_PHYSICAL" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || [ "$PROJECT_TOPLEVEL" != "$PROJECT_PHYSICAL" ]; then
      add_blocker project_not_worktree "Project is not an ordinary Git working tree"
    else
      PROJECT_GIT_DIR=$(fmp_git_absolute_dir "$PROJECT_PHYSICAL" git 2>/dev/null) || PROJECT_GIT_DIR=
      PROJECT_COMMON_DIR=$(fmp_git_absolute_dir "$PROJECT_PHYSICAL" common 2>/dev/null) || PROJECT_COMMON_DIR=
      [ -n "$PROJECT_GIT_DIR" ] || add_blocker git_dir_unreadable "Project Git directory cannot be resolved"
      [ -n "$PROJECT_COMMON_DIR" ] || add_blocker common_dir_unreadable "Project common Git directory cannot be resolved"
      OBJECT_FORMAT=$(fmp_git_object_format "$PROJECT_PHYSICAL")

      ORIGIN_RAW=$(git -C "$PROJECT_PHYSICAL" remote get-url origin 2>/dev/null) || ORIGIN_RAW=
      if [ -n "$ORIGIN_RAW" ]; then
        ORIGIN_PRESENT=true
        ORIGIN_REDACTED=$(fmp_redact_origin "$ORIGIN_RAW")
        ORIGIN_IDENTITY=$(printf '%s' "$ORIGIN_REDACTED" | fmp_fingerprint)
        if fmp_origin_has_http_credentials "$ORIGIN_RAW"; then
          add_blocker origin_embedded_credentials "Origin contains embedded HTTP credentials or query/fragment material; sensitive text was redacted"
        fi
      else
        add_blocker no_origin "Project has no origin remote"
      fi

      DEFAULT_BRANCH=$(fmp_git_default_branch "$PROJECT_PHYSICAL" 2>/dev/null) || DEFAULT_BRANCH=
      if [ -z "$DEFAULT_BRANCH" ]; then
        add_blocker default_branch_unknown "Remote default branch cannot be determined from local refs"
      fi
      CURRENT_BRANCH=$(git -C "$PROJECT_PHYSICAL" symbolic-ref --quiet --short HEAD 2>/dev/null) || CURRENT_BRANCH=DETACHED
      if [ -n "$DEFAULT_BRANCH" ] && [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
        OFF_DEFAULT=true
        add_blocker off_default "Project checkout is not on its remote default branch"
      fi

      if [ -n "$(git -C "$PROJECT_PHYSICAL" status --porcelain=v1 --untracked-files=normal 2>/dev/null)" ]; then
        DIRTY=true
        add_blocker dirty_worktree "Project checkout has uncommitted or untracked changes"
      fi

      if [ -n "$DEFAULT_BRANCH" ] \
        && git -C "$PROJECT_PHYSICAL" rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH^{commit}" >/dev/null 2>&1 \
        && git -C "$PROJECT_PHYSICAL" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH^{commit}" >/dev/null 2>&1; then
        COUNTS=$(git -C "$PROJECT_PHYSICAL" rev-list --left-right --count "$DEFAULT_BRANCH...origin/$DEFAULT_BRANCH" 2>/dev/null) || COUNTS=
        if [ -n "$COUNTS" ]; then
          DEFAULT_AHEAD=${COUNTS%%[[:space:]]*}
          DEFAULT_BEHIND=${COUNTS##*[[:space:]]}
          if [ "$DEFAULT_AHEAD" -gt 0 ] && [ "$DEFAULT_BEHIND" -gt 0 ]; then
            DIVERGED=true
            add_blocker default_diverged "Local and remote default branches have diverged"
          elif [ "$DEFAULT_AHEAD" -gt 0 ]; then
            add_blocker default_ahead "Local default branch is ahead of its origin default ref"
          elif [ "$DEFAULT_BEHIND" -gt 0 ]; then
            add_warning default_behind "Local default branch is behind its cached origin ref"
          fi
        fi
      fi

      UNPUSHED_COUNT=$(git -C "$PROJECT_PHYSICAL" rev-list --count --branches --not --remotes 2>/dev/null) || UNPUSHED_COUNT=0
      case "$UNPUSHED_COUNT" in ''|*[!0-9]*) UNPUSHED_COUNT=0 ;; esac
      if [ "$UNPUSHED_COUNT" -gt 0 ]; then
        add_blocker unpushed_commits "Local branches contain commits not reachable from any remote ref"
      fi

      if [ "$(git -C "$PROJECT_PHYSICAL" rev-parse --is-shallow-repository 2>/dev/null || echo false)" = true ]; then
        SHALLOW=true
        add_blocker shallow_repository "Project is shallow"
      fi
      if git -C "$PROJECT_PHYSICAL" config --get extensions.partialClone >/dev/null 2>&1 \
        || git -C "$PROJECT_PHYSICAL" config --get-regexp '^remote\..*\.partialclonefilter$' >/dev/null 2>&1; then
        PARTIAL=true
        add_blocker partial_clone "Project uses partial-clone configuration"
      fi
      if git -C "$PROJECT_PHYSICAL" config --get-regexp '^remote\..*\.promisor$' 2>/dev/null \
        | awk '$NF == "true" { found=1 } END { exit found ? 0 : 1 }'; then
        PROMISOR=true
        add_blocker promisor_remote "Project has a promisor remote"
      fi
      REPLACE_REF_COUNT=$(git -C "$PROJECT_PHYSICAL" for-each-ref --format='%(refname)' refs/replace 2>/dev/null | awk 'NF { n++ } END { print n+0 }')
      if [ "$REPLACE_REF_COUNT" -gt 0 ]; then
        add_blocker replace_refs "Project has replace refs"
      fi
      if [ -n "$PROJECT_COMMON_DIR" ] && [ -s "$PROJECT_COMMON_DIR/info/grafts" ]; then
        GRAFTS=true
        add_blocker grafts "Project has legacy grafts"
      fi
      ALTERNATES_PATH=$(git -C "$PROJECT_PHYSICAL" rev-parse --path-format=absolute --git-path objects/info/alternates 2>/dev/null) || ALTERNATES_PATH=
      if [ -n "$ALTERNATES_PATH" ] && [ -s "$ALTERNATES_PATH" ]; then
        ALTERNATE=true
        add_blocker unexpected_alternate "Project already borrows from an alternate object store"
      fi
      if [ -n "$AMBIENT_GIT_ALTERNATES" ]; then
        ALTERNATE=true
        add_blocker ambient_alternate "GIT_ALTERNATE_OBJECT_DIRECTORIES is set in the preflight environment"
      fi
      if git -C "$PROJECT_PHYSICAL" remote get-url no-mistakes >/dev/null 2>&1; then
        NO_MISTAKES_REMOTE=true
      fi

      WORKTREE_DATA=$(git -C "$PROJECT_PHYSICAL" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || WORKTREE_DATA=
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          worktree\ *)
            WORKTREE_PATH=${line#worktree }
            WORKTREE_COUNT=$((WORKTREE_COUNT + 1))
            if ! paths_match "$WORKTREE_PATH" "$PROJECT_PHYSICAL"; then
              EXTRA_WORKTREE_COUNT=$((EXTRA_WORKTREE_COUNT + 1))
              EXTRA_WORKTREES+=("$WORKTREE_PATH")
              case "$WORKTREE_PATH" in
                */.no-mistakes/*) NO_MISTAKES_WORKTREE_COUNT=$((NO_MISTAKES_WORKTREE_COUNT + 1)) ;;
              esac
            fi
            ;;
        esac
      done <<EOF
$WORKTREE_DATA
EOF
      if [ "$EXTRA_WORKTREE_COUNT" -gt 0 ]; then
        add_blocker linked_worktrees "Project has linked worktrees beyond its control checkout"
      fi
      if [ "$NO_MISTAKES_WORKTREE_COUNT" -gt 0 ]; then
        add_blocker no_mistakes_run_worktree "Project has a linked no-mistakes worktree"
      fi
    fi
  fi
fi

REGISTRY="$HOME_PHYSICAL/data/projects.md"
if [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] \
  && awk -v n="$PROJECT_NAME" '$1 == "-" && $2 == n { found=1 } END { exit found ? 0 : 1 }' "$REGISTRY"; then
  REGISTERED=true
  MODE_LINE=$(FM_HOME="$HOME_PHYSICAL" "$FM_ROOT/bin/fm-project-mode.sh" "$PROJECT_NAME" 2>/dev/null) || MODE_LINE="unknown unknown"
  REGISTERED_MODE=${MODE_LINE%% *}
  REGISTERED_YOLO=${MODE_LINE##* }
else
  add_blocker unregistered_project "Project is not present in the supplied home's registry"
fi

STATE_DIR="$HOME_PHYSICAL/state"
if [ -d "$STATE_DIR" ] && [ -n "$PROJECT_PHYSICAL" ]; then
  for META in "$STATE_DIR"/*.meta; do
    [ -f "$META" ] && [ ! -L "$META" ] || continue
    META_PROJECT=$(fmp_meta_value "$META" project)
    [ -n "$META_PROJECT" ] || continue
    if paths_match "$META_PROJECT" "$PROJECT_PHYSICAL"; then
      TASK_ID=$(basename "$META" .meta)
      LIVE_TASK_IDS+=("$TASK_ID")
      META_WINDOW=$(fmp_meta_value "$META" window)
      META_ENDPOINT_ID=$(fmp_meta_value "$META" endpoint_task_id)
      if [ -n "$META_WINDOW$META_ENDPOINT_ID" ]; then
        ENDPOINT_COUNT=$((ENDPOINT_COUNT + 1))
      fi
      META_BACKEND=$(fmp_meta_value "$META" backend)
      META_ORCA_ID=$(fmp_meta_value "$META" orca_worktree_id)
      if [ "$META_BACKEND" = orca ] || [ -n "$META_ORCA_ID" ]; then
        ORCA_COUNT=$((ORCA_COUNT + 1))
      fi
    fi
  done
  if [ "${#LIVE_TASK_IDS[@]}" -gt 0 ]; then
    add_blocker live_task_metadata "Home has live task metadata naming this project"
  fi
  if [ "$ENDPOINT_COUNT" -gt 0 ]; then
    add_blocker live_endpoint "Live task metadata carries endpoint identity"
  fi
  if [ "$ORCA_COUNT" -gt 0 ]; then
    add_blocker live_orca "Live task metadata carries Orca identity"
  fi

  if [ -d "$STATE_DIR/pending-replies" ]; then
    for REPLY in "$STATE_DIR/pending-replies"/*; do
      [ -f "$REPLY" ] && [ ! -L "$REPLY" ] || continue
      [ "$(fmp_meta_value "$REPLY" schema)" = fm-pending-reply.v1 ] || continue
      REPLY_PHASE=$(fmp_meta_value "$REPLY" phase)
      [ "$REPLY_PHASE" != resolved ] || continue
      REPLY_TASK=$(fmp_meta_value "$REPLY" task_id)
      [ -n "$REPLY_TASK" ] || continue
      if array_contains "$REPLY_TASK" "${LIVE_TASK_IDS[@]:-}"; then
        PENDING_REPLY_COUNT=$((PENDING_REPLY_COUNT + 1))
      fi
    done
    if [ "$PENDING_REPLY_COUNT" -gt 0 ]; then
      add_blocker pending_reply "An unresolved pending reply is tied to live project work"
    fi
  fi
fi

# Inspect only explicitly registered local sibling homes. Remote paths are never
# resolved or combined with this host's cache proposal.
if [ -f "$HOME_PHYSICAL/data/secondmates.md" ] && [ ! -L "$HOME_PHYSICAL/data/secondmates.md" ] \
  && [ -n "$ORIGIN_RAW" ]; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$FM_ROOT/bin/fm-secondmate-registry-lib.sh"
  while IFS= read -r REGISTRY_LINE || [ -n "$REGISTRY_LINE" ]; do
    case "$REGISTRY_LINE" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$REGISTRY_LINE" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if fmp_csv_contains "$SECONDMATE_REGISTRY_PROJECTS" "$PROJECT_NAME"; then
        REMOTE_BORROWER_COUNT=$((REMOTE_BORROWER_COUNT + 1))
      fi
      continue
    fi
    ! paths_match "$SECONDMATE_REGISTRY_HOME" "$HOME_PHYSICAL" || continue
    SIBLING_PROJECT="$SECONDMATE_REGISTRY_HOME/projects/$PROJECT_NAME"
    [ -d "$SIBLING_PROJECT" ] || continue
    SIBLING_ORIGIN=$(git -C "$SIBLING_PROJECT" remote get-url origin 2>/dev/null) || SIBLING_ORIGIN=
    [ "$SIBLING_ORIGIN" = "$ORIGIN_RAW" ] || continue
    SIBLING_BORROWER_COUNT=$((SIBLING_BORROWER_COUNT + 1))
    for SIBLING_META in "$SECONDMATE_REGISTRY_HOME/state"/*.meta; do
      [ -f "$SIBLING_META" ] && [ ! -L "$SIBLING_META" ] || continue
      SIBLING_META_PROJECT=$(fmp_meta_value "$SIBLING_META" project)
      [ -n "$SIBLING_META_PROJECT" ] || continue
      paths_match "$SIBLING_META_PROJECT" "$SIBLING_PROJECT" || continue
      SIBLING_ID=$(basename "$SIBLING_META" .meta)
      if array_contains "$SIBLING_ID" "${LIVE_TASK_IDS[@]:-}" \
        && ! array_contains "$SIBLING_ID" "${DUPLICATE_BRANCH_IDS[@]:-}"; then
        DUPLICATE_BRANCH_IDS+=("$SIBLING_ID")
      fi
    done
  done < "$HOME_PHYSICAL/data/secondmates.md"
  if [ "${#DUPLICATE_BRANCH_IDS[@]}" -gt 0 ]; then
    add_blocker duplicate_cross_home_branch "Two local homes have live work that maps to the same fm/<id> branch"
  fi
  if [ "$REMOTE_BORROWER_COUNT" -gt 0 ]; then
    add_warning remote_home_unverified "Registered remote homes are out of local inspection scope and receive no local cache path"
  fi
fi

CANONICAL_PHYSICAL=
CANONICAL_GIT_DIR=
CANONICAL_COMMON_DIR=
CANONICAL_ORIGIN_REDACTED=
if [ -n "$CANONICAL_ARG" ]; then
  if ! fmp_absolute_path_is_lexically_safe "$CANONICAL_ARG"; then
    add_blocker canonical_path_unsafe "Canonical navigation path is not a traversal-free absolute path"
  elif [ ! -d "$CANONICAL_ARG" ]; then
    add_blocker canonical_path_missing "Canonical navigation path does not exist"
  else
    CANONICAL_PHYSICAL=$(fmp_existing_path_physical "$CANONICAL_ARG") || CANONICAL_PHYSICAL=
    if fmp_path_has_symlink_component "$CANONICAL_ARG"; then
      add_blocker canonical_path_symlink "Canonical navigation path has a symlink component"
    fi
    if [ -n "$PROJECT_PHYSICAL" ] && [ "$CANONICAL_PHYSICAL" = "$PROJECT_PHYSICAL" ]; then
      add_blocker canonical_is_control "Canonical human checkout is the Firstmate control checkout"
    fi
    if [ -z "$CANONICAL_PHYSICAL" ]; then
      add_blocker canonical_unresolved "Canonical navigation path could not be resolved to a readable physical directory"
    elif git -C "$CANONICAL_PHYSICAL" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      CANONICAL_GIT_DIR=$(fmp_git_absolute_dir "$CANONICAL_PHYSICAL" git 2>/dev/null) || CANONICAL_GIT_DIR=
      CANONICAL_COMMON_DIR=$(fmp_git_absolute_dir "$CANONICAL_PHYSICAL" common 2>/dev/null) || CANONICAL_COMMON_DIR=
      if [ -n "$PROJECT_COMMON_DIR" ] && [ "$CANONICAL_COMMON_DIR" = "$PROJECT_COMMON_DIR" ]; then
        add_blocker canonical_shares_common_dir "Canonical human checkout shares Firstmate's common Git directory"
      fi
      CANONICAL_ORIGIN_RAW=$(git -C "$CANONICAL_PHYSICAL" remote get-url origin 2>/dev/null) || CANONICAL_ORIGIN_RAW=
      CANONICAL_ORIGIN_REDACTED=$(fmp_redact_origin "$CANONICAL_ORIGIN_RAW")
      if [ -n "$ORIGIN_RAW" ] && [ -n "$CANONICAL_ORIGIN_RAW" ] && [ "$CANONICAL_ORIGIN_RAW" != "$ORIGIN_RAW" ]; then
        add_blocker canonical_origin_mismatch "Canonical checkout origin differs from the control checkout origin"
      fi
    else
      add_warning canonical_not_git "Canonical navigation path is not a Git working tree"
    fi
  fi
fi

CACHE_PHYSICAL=
CACHE_UID=unknown
CACHE_MODE=unknown
CACHE_FILESYSTEM_SOURCE=
CACHE_FILESYSTEM_LOCALITY=not-supplied
CACHE_IS_GIT=false
CACHE_IS_BARE=false
CACHE_ORIGIN_REDACTED=
CACHE_OBJECT_FORMAT=unknown
if [ -n "$CACHE_ARG" ]; then
  if ! fmp_absolute_path_is_lexically_safe "$CACHE_ARG"; then
    add_blocker cache_path_unsafe "Proposed cache path is not a traversal-free absolute path"
  elif fmp_path_has_symlink_component "$CACHE_ARG"; then
    add_blocker cache_symlink "Proposed cache path has a symlink component"
  elif [ ! -d "$CACHE_ARG" ]; then
    add_blocker cache_missing "Proposed cache repository does not exist; preflight will not create it"
    CACHE_ANCESTOR=$(fmp_nearest_existing_ancestor "$CACHE_ARG" 2>/dev/null) || CACHE_ANCESTOR=
    if [ -n "$CACHE_ANCESTOR" ]; then
      CACHE_FILESYSTEM_SOURCE=$(fmp_filesystem_source "$CACHE_ANCESTOR")
      CACHE_FILESYSTEM_LOCALITY=$(fmp_filesystem_locality "$CACHE_FILESYSTEM_SOURCE")
    fi
  else
    CACHE_PHYSICAL=$(fmp_existing_path_physical "$CACHE_ARG") || CACHE_PHYSICAL=
    if [ -z "$CACHE_PHYSICAL" ]; then
      add_blocker cache_unresolved "Proposed cache path could not be resolved to a readable physical directory"
    else
      CACHE_UID=$(fmp_stat_uid "$CACHE_PHYSICAL" 2>/dev/null) || CACHE_UID=unknown
      CACHE_MODE=$(fmp_stat_mode "$CACHE_PHYSICAL" 2>/dev/null) || CACHE_MODE=unknown
      if [ "$CACHE_UID" != "$CURRENT_UID" ]; then
        add_blocker cache_owner_mismatch "Proposed cache is not owned by the current user"
      fi
      if [ "$CACHE_MODE" = unknown ] || fmp_mode_group_or_world_writable "$CACHE_MODE"; then
        add_blocker cache_permissions "Proposed cache is not verifiably owner-only"
      fi
      CACHE_FILESYSTEM_SOURCE=$(fmp_filesystem_source "$CACHE_PHYSICAL")
      CACHE_FILESYSTEM_LOCALITY=$(fmp_filesystem_locality "$CACHE_FILESYSTEM_SOURCE")
      case "$CACHE_FILESYSTEM_LOCALITY" in
        local) ;;
        network) add_blocker cache_network_filesystem "Proposed cache is on a network filesystem" ;;
        *) add_blocker cache_filesystem_unknown "Proposed cache filesystem locality cannot be proved" ;;
      esac
      if git -C "$CACHE_PHYSICAL" rev-parse --git-dir >/dev/null 2>&1; then
        CACHE_IS_GIT=true
        if [ "$(git -C "$CACHE_PHYSICAL" rev-parse --is-bare-repository 2>/dev/null || echo false)" = true ]; then
          CACHE_IS_BARE=true
        else
          add_blocker cache_not_bare "Proposed per-project cache is not a bare repository"
        fi
        CACHE_OBJECT_FORMAT=$(fmp_git_object_format "$CACHE_PHYSICAL")
        CACHE_ORIGIN_RAW=$(git -C "$CACHE_PHYSICAL" remote get-url origin 2>/dev/null) || CACHE_ORIGIN_RAW=
        CACHE_ORIGIN_REDACTED=$(fmp_redact_origin "$CACHE_ORIGIN_RAW")
        if [ -z "$CACHE_ORIGIN_RAW" ]; then
          add_blocker cache_no_origin "Proposed cache has no origin remote"
        elif fmp_origin_has_http_credentials "$CACHE_ORIGIN_RAW"; then
          add_blocker cache_embedded_credentials "Proposed cache origin contains embedded HTTP credentials or query/fragment material; sensitive text was redacted"
        elif [ -n "$ORIGIN_RAW" ] && [ "$CACHE_ORIGIN_RAW" != "$ORIGIN_RAW" ]; then
          add_blocker cache_origin_mismatch "Proposed cache origin differs from the control checkout origin"
        fi
        if [ "$OBJECT_FORMAT" != unknown ] && [ "$CACHE_OBJECT_FORMAT" != "$OBJECT_FORMAT" ]; then
          add_blocker cache_object_format_mismatch "Proposed cache and control checkout use different object formats"
        fi
        CACHE_ALTERNATES=$(git -C "$CACHE_PHYSICAL" rev-parse --path-format=absolute --git-path objects/info/alternates 2>/dev/null) || CACHE_ALTERNATES=
        if [ -n "$CACHE_ALTERNATES" ] && [ -s "$CACHE_ALTERNATES" ]; then
          add_blocker cache_has_alternate "Proposed cache itself borrows objects from another store"
        fi
      else
        add_blocker cache_not_git "Proposed cache is not a Git repository"
      fi
    fi
  fi
fi

STATUS=ready
[ "${#BLOCKER_CODES[@]}" -eq 0 ] || STATUS=blocked

FINGERPRINT=$({
  printf 'schema=fm-project-layout-preflight.v1\n'
  printf 'home=%s\nproject=%s\nname=%s\n' "$HOME_PHYSICAL" "$PROJECT_PHYSICAL" "$PROJECT_NAME"
  printf 'registered=%s\nmode=%s\nyolo=%s\n' "$REGISTERED" "$REGISTERED_MODE" "$REGISTERED_YOLO"
  printf 'origin=%s\nobject-format=%s\ndefault=%s\nbranch=%s\n' "$ORIGIN_REDACTED" "$OBJECT_FORMAT" "$DEFAULT_BRANCH" "$CURRENT_BRANCH"
  printf 'dirty=%s\noff-default=%s\ndiverged=%s\nunpushed=%s\n' "$DIRTY" "$OFF_DEFAULT" "$DIVERGED" "$UNPUSHED_COUNT"
  printf 'shallow=%s\npartial=%s\npromisor=%s\nreplace=%s\ngrafts=%s\nalternate=%s\n' \
    "$SHALLOW" "$PARTIAL" "$PROMISOR" "$REPLACE_REF_COUNT" "$GRAFTS" "$ALTERNATE"
  printf 'worktrees=%s\ntasks=%s\nendpoints=%s\nfixed-orca=%s\npending=%s\n' \
    "$WORKTREE_COUNT" "${#LIVE_TASK_IDS[@]}" "$ENDPOINT_COUNT" "$ORCA_COUNT" "$PENDING_REPLY_COUNT"
  printf 'task-ids='
  printf '%s,' "${LIVE_TASK_IDS[@]:-}"
  printf '\nextra-worktrees='
  printf '%s,' "${EXTRA_WORKTREES[@]:-}"
  printf '\nduplicate-branch-ids='
  printf '%s,' "${DUPLICATE_BRANCH_IDS[@]:-}"
  printf '\n'
  printf 'cache-requested=%s\ncache=%s\ncache-origin=%s\ncache-format=%s\ncache-locality=%s\n' \
    "$CACHE_ARG" "$CACHE_PHYSICAL" "$CACHE_ORIGIN_REDACTED" "$CACHE_OBJECT_FORMAT" "$CACHE_FILESYSTEM_LOCALITY"
  printf 'canonical-requested=%s\ncanonical=%s\nsibling-borrowers=%s\nremote-borrowers=%s\n' \
    "$CANONICAL_ARG" "$CANONICAL_PHYSICAL" "$SIBLING_BORROWER_COUNT" "$REMOTE_BORROWER_COUNT"
  printf 'blockers='
  printf '%s,' "${BLOCKER_CODES[@]:-}"
  printf '\nwarnings='
  printf '%s,' "${WARNING_CODES[@]:-}"
  printf '\n'
} | fmp_fingerprint)

emit_json_string_array() {
  local first=1 value
  printf '['
  for value in "$@"; do
    [ -n "$value" ] || continue
    [ "$first" -eq 1 ] || printf ','
    printf '"%s"' "$(fmp_json_escape "$value")"
    first=0
  done
  printf ']'
}

emit_json_findings() {
  local kind=$1 i count
  if [ "$kind" = blockers ]; then
    count=${#BLOCKER_CODES[@]}
  else
    count=${#WARNING_CODES[@]}
  fi
  printf '['
  i=0
  while [ "$i" -lt "$count" ]; do
    [ "$i" -eq 0 ] || printf ','
    if [ "$kind" = blockers ]; then
      printf '{"code":"%s","detail":"%s"}' \
        "$(fmp_json_escape "${BLOCKER_CODES[$i]}")" "$(fmp_json_escape "${BLOCKER_DETAILS[$i]}")"
    else
      printf '{"code":"%s","detail":"%s"}' \
        "$(fmp_json_escape "${WARNING_CODES[$i]}")" "$(fmp_json_escape "${WARNING_DETAILS[$i]}")"
    fi
    i=$((i + 1))
  done
  printf ']'
}

emit_json() {
  printf '{'
  printf '"schema":"fm-project-layout-preflight.v1",'
  printf '"status":"%s","read_only":true,' "$STATUS"
  printf '"home":{"requested":"%s","physical":"%s","uid":"%s","mode":"%s"},' \
    "$(fmp_json_escape "$HOME_ARG")" "$(fmp_json_escape "$HOME_PHYSICAL")" "$HOME_UID" "$HOME_MODE"
  printf '"project":{"name":"%s","requested":"%s","physical":"%s","git_dir":"%s","common_dir":"%s","uid":"%s","mode":"%s"},' \
    "$(fmp_json_escape "$PROJECT_NAME")" "$(fmp_json_escape "$PROJECT_REQUESTED")" \
    "$(fmp_json_escape "$PROJECT_PHYSICAL")" "$(fmp_json_escape "$PROJECT_GIT_DIR")" \
    "$(fmp_json_escape "$PROJECT_COMMON_DIR")" "$PROJECT_UID" "$PROJECT_MODE"
  printf '"registration":{"registered":%s,"mode":"%s","yolo":"%s"},' \
    "$REGISTERED" "$(fmp_json_escape "$REGISTERED_MODE")" "$(fmp_json_escape "$REGISTERED_YOLO")"
  printf '"repository":{"origin_present":%s,"origin":"%s","origin_identity":"%s","default_branch":"%s","current_branch":"%s","object_format":"%s","dirty":%s,"off_default":%s,"diverged":%s,"ahead":%s,"behind":%s,"unpushed_commits":%s,"shallow":%s,"partial":%s,"promisor":%s,"replace_refs":%s,"grafts":%s,"alternate":%s,"no_mistakes_remote":%s},' \
    "$ORIGIN_PRESENT" "$(fmp_json_escape "$ORIGIN_REDACTED")" "$(fmp_json_escape "$ORIGIN_IDENTITY")" \
    "$(fmp_json_escape "$DEFAULT_BRANCH")" "$(fmp_json_escape "$CURRENT_BRANCH")" "$(fmp_json_escape "$OBJECT_FORMAT")" \
    "$DIRTY" "$OFF_DEFAULT" "$DIVERGED" "$DEFAULT_AHEAD" "$DEFAULT_BEHIND" "$UNPUSHED_COUNT" \
    "$SHALLOW" "$PARTIAL" "$PROMISOR" "$REPLACE_REF_COUNT" "$GRAFTS" "$ALTERNATE" "$NO_MISTAKES_REMOTE"
  printf '"live":{"worktree_count":%s,"extra_worktree_count":%s,"no_mistakes_worktree_count":%s,"task_ids":' \
    "$WORKTREE_COUNT" "$EXTRA_WORKTREE_COUNT" "$NO_MISTAKES_WORKTREE_COUNT"
  emit_json_string_array "${LIVE_TASK_IDS[@]:-}"
  printf ',"endpoint_count":%s,"orca_count":%s,"pending_reply_count":%s,"sibling_borrower_count":%s,"remote_borrower_count":%s,"duplicate_branch_ids":' \
    "$ENDPOINT_COUNT" "$ORCA_COUNT" "$PENDING_REPLY_COUNT" "$SIBLING_BORROWER_COUNT" "$REMOTE_BORROWER_COUNT"
  emit_json_string_array "${DUPLICATE_BRANCH_IDS[@]:-}"
  printf '},'
  printf '"proposal":{"cache_root":"%s","cache_physical":"%s","cache_uid":"%s","cache_mode":"%s","cache_filesystem":"%s","cache_locality":"%s","cache_is_git":%s,"cache_is_bare":%s,"cache_origin":"%s","cache_object_format":"%s","canonical_path":"%s","canonical_physical":"%s","canonical_git_dir":"%s","canonical_common_dir":"%s","canonical_origin":"%s"},' \
    "$(fmp_json_escape "$CACHE_ARG")" "$(fmp_json_escape "$CACHE_PHYSICAL")" "$CACHE_UID" "$CACHE_MODE" \
    "$(fmp_json_escape "$CACHE_FILESYSTEM_SOURCE")" "$CACHE_FILESYSTEM_LOCALITY" "$CACHE_IS_GIT" "$CACHE_IS_BARE" \
    "$(fmp_json_escape "$CACHE_ORIGIN_REDACTED")" "$CACHE_OBJECT_FORMAT" \
    "$(fmp_json_escape "$CANONICAL_ARG")" "$(fmp_json_escape "$CANONICAL_PHYSICAL")" \
    "$(fmp_json_escape "$CANONICAL_GIT_DIR")" "$(fmp_json_escape "$CANONICAL_COMMON_DIR")" \
    "$(fmp_json_escape "$CANONICAL_ORIGIN_REDACTED")"
  printf '"blockers":'; emit_json_findings blockers
  printf ',"warnings":'; emit_json_findings warnings
  printf ',"fingerprint":{"algorithm":"posix-cksum","value":"%s","cutover_authority":false}' "$(fmp_json_escape "$FINGERPRINT")"
  printf '}\n'
}

emit_text() {
  local i
  printf 'project layout preflight: %s\n' "$STATUS"
  printf 'schema: fm-project-layout-preflight.v1\n'
  printf 'read-only: true\n'
  printf 'home: %s\n' "$HOME_PHYSICAL"
  printf 'project: %s\n' "$PROJECT_PHYSICAL"
  printf 'registered posture: %s yolo=%s\n' "$REGISTERED_MODE" "$REGISTERED_YOLO"
  printf 'origin: %s\n' "${ORIGIN_REDACTED:-none}"
  printf 'git dirs: git=%s common=%s\n' "$PROJECT_GIT_DIR" "$PROJECT_COMMON_DIR"
  printf 'branch: current=%s default=%s ahead=%s behind=%s\n' "$CURRENT_BRANCH" "$DEFAULT_BRANCH" "$DEFAULT_AHEAD" "$DEFAULT_BEHIND"
  printf 'object format: %s\n' "$OBJECT_FORMAT"
  printf 'live evidence: worktrees=%s extra=%s tasks=%s endpoints=%s orca=%s pending-replies=%s\n' \
    "$WORKTREE_COUNT" "$EXTRA_WORKTREE_COUNT" "${#LIVE_TASK_IDS[@]}" "$ENDPOINT_COUNT" "$ORCA_COUNT" "$PENDING_REPLY_COUNT"
  printf 'cache proposal: %s locality=%s format=%s\n' "${CACHE_PHYSICAL:-${CACHE_ARG:-not-supplied}}" "$CACHE_FILESYSTEM_LOCALITY" "$CACHE_OBJECT_FORMAT"
  printf 'canonical navigation path: %s\n' "${CANONICAL_PHYSICAL:-${CANONICAL_ARG:-not-supplied}}"
  printf 'blockers: %s\n' "${#BLOCKER_CODES[@]}"
  i=0
  while [ "$i" -lt "${#BLOCKER_CODES[@]}" ]; do
    printf -- '- %s: %s\n' "${BLOCKER_CODES[$i]}" "${BLOCKER_DETAILS[$i]}"
    i=$((i + 1))
  done
  printf 'warnings: %s\n' "${#WARNING_CODES[@]}"
  i=0
  while [ "$i" -lt "${#WARNING_CODES[@]}" ]; do
    printf -- '- %s: %s\n' "${WARNING_CODES[$i]}" "${WARNING_DETAILS[$i]}"
    i=$((i + 1))
  done
  printf 'evidence fingerprint: %s\n' "$FINGERPRINT"
  printf 'cutover authority: false (a future mutating tool must re-check every fact)\n'
}

if [ "$JSON" -eq 1 ]; then
  emit_json
else
  emit_text
fi

[ "$STATUS" = ready ]
