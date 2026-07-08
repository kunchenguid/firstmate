#!/usr/bin/env bash
# Resolve firstmate project identity and canonical checkout paths.
#
# Machine registry format: data/projects.json
# {
#   "schemaVersion": 1,
#   "projects": [
#     {
#       "projectId": "flow",
#       "canonicalPath": "/absolute/path/to/flow",
#       "gitCommonDir": "/absolute/path/to/flow/.git",
#       "remotes": { "origin": "https://github.com/org/flow.git", "fork": "..." },
#       "defaultBranch": "dev",
#       "baseRef": "refs/remotes/origin/dev",
#       "mode": "no-mistakes",
#       "yolo": false,
#       "worktreePolicy": "firstmate-owned"
#     }
#   ]
# }
#
# Usage:
#   fm-project-resolve.sh [--json] <project-id-or-path>
#   fm-project-resolve.sh --field <field> <project-id-or-path>
#   fm-project-resolve.sh --shell <project-id-or-path>
#   fm-project-resolve.sh --list
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
JSON_REG="$DATA/projects.json"
MD_REG="$DATA/projects.md"

usage() {
  echo "usage: fm-project-resolve.sh [--json|--shell|--field <field>|--list] [<project-id-or-path>]" >&2
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

path_is_ancestor_or_self() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  if [ "$ancestor" = "$path" ]; then
    return 0
  fi
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

real_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

git_path_real() {
  local repo=$1 path=$2
  case "$path" in
    /*) real_existing_dir "$path" ;;
    *) real_existing_dir "$repo/$path" ;;
  esac
}

markdown_mode_yolo() {
  local name=$1 parsed mode yolo
  if [ ! -f "$MD_REG" ]; then
    echo "warn: no registry at $MD_REG; defaulting $name to no-mistakes off" >&2
    echo "no-mistakes off"
    return 0
  fi
  parsed=$(awk -v n="$name" '
    $1=="-" && $2==n {
      mode="no-mistakes"; yolo="off";
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
      }
      print mode, yolo; exit
    }
  ' "$MD_REG")
  if [ -z "$parsed" ]; then
    echo "warn: project \"$name\" not in registry; defaulting to no-mistakes off" >&2
    echo "no-mistakes off"
    return 0
  fi
  mode=${parsed%% *}
  yolo=${parsed##* }
  case "$mode" in
    no-mistakes|direct-PR|local-only) ;;
    *) echo "warn: unknown mode \"$mode\" for $name; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
  esac
  case "$yolo" in on|off) ;; *) yolo=off ;; esac
  echo "$mode $yolo"
}

fallback_project_id() {
  local arg=$1 arg_real projects_real
  case "$arg" in
    projects/*) basename "$arg" ;;
    */*)
      arg_real=$(real_existing_dir "$arg" 2>/dev/null || true)
      projects_real=$(real_existing_dir "$PROJECTS" 2>/dev/null || true)
      if [ -n "$arg_real" ] && [ -n "$projects_real" ] && path_is_ancestor_or_self "$projects_real" "$arg_real"; then
        basename "$arg"
      else
        printf '%s\n' "$arg"
      fi
      ;;
    *) printf '%s\n' "$arg" ;;
  esac
}

fallback_project_path() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      ;;
    */*)
      candidate="$arg"
      ;;
    *)
      candidate="$PROJECTS/$arg"
      ;;
  esac
  if [ -d "$candidate" ]; then
    real_existing_dir "$candidate"
  else
    printf '%s\n' "$candidate"
  fi
}

fallback_default_branch() {
  local path=$1 ref branch
  [ -d "$path" ] || return 0
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  ref=$(git -C "$path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$path" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
}

json_registry_project() {
  local arg=$1 arg_real matches count entries entry candidate candidate_real matched_count matched_entry
  arg_real=
  [ -f "$JSON_REG" ] || return 1
  command -v jq >/dev/null 2>&1 || {
    echo "error: $JSON_REG exists but jq is not installed" >&2
    return 2
  }
  if [ -d "$arg" ]; then
    arg_real=$(real_existing_dir "$arg")
  fi
  matches=$(jq -c --arg arg "$arg" '[.projects[]? | select((.projectId // "") == $arg)]' "$JSON_REG") || return 2
  count=$(printf '%s\n' "$matches" | jq -r 'length') || return 2
  if [ "$count" -gt 1 ]; then
    echo "error: duplicate projectId in $JSON_REG: $arg" >&2
    return 2
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$matches" | jq -c '.[0]'
    return 0
  fi

  matches=$(jq -c --arg arg "$arg" '[.projects[]? | select((.canonicalPath // "") == $arg)]' "$JSON_REG") || return 2
  count=$(printf '%s\n' "$matches" | jq -r 'length') || return 2
  if [ "$count" -gt 1 ]; then
    echo "error: duplicate canonicalPath in $JSON_REG: $arg" >&2
    return 2
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$matches" | jq -c '.[0]'
    return 0
  fi

  [ -n "$arg_real" ] || return 1
  entries=$(jq -c '.projects[]?' "$JSON_REG") || return 2
  matched_count=0
  matched_entry=
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    candidate=$(printf '%s\n' "$entry" | jq -r '.canonicalPath // empty') || return 2
    [ -n "$candidate" ] || continue
    candidate_real=$(real_existing_dir "$candidate" 2>/dev/null || true)
    if [ -n "$candidate_real" ] && [ "$candidate_real" = "$arg_real" ]; then
      matched_count=$((matched_count + 1))
      [ "$matched_count" -ne 1 ] || matched_entry=$entry
    fi
  done <<EOF
$entries
EOF
  if [ "$matched_count" -gt 1 ]; then
    echo "error: duplicate canonicalPath in $JSON_REG: $arg_real" >&2
    return 2
  fi
  if [ "$matched_count" -eq 1 ]; then
    printf '%s\n' "$matched_entry"
    return 0
  fi
  return 1
}

validate_canonical_path() {
  local project_id=$1 canonical=$2 expected_common=$3 codex_home codex_worktrees toplevel toplevel_real gitdir common gitdir_real common_real
  case "$canonical" in
    /*) ;;
    *) echo "error: project $project_id canonicalPath must be absolute: $canonical" >&2; return 1 ;;
  esac
  [ "$canonical" != "/" ] || { echo "error: project $project_id canonicalPath cannot be filesystem root" >&2; return 1; }
  [ -d "$canonical" ] || { echo "error: project $project_id canonicalPath is not a directory: $canonical" >&2; return 1; }

  codex_home=${CODEX_HOME:-$HOME/.codex}
  if [ -d "$codex_home/worktrees" ]; then
    codex_worktrees=$(real_existing_dir "$codex_home/worktrees")
    if path_is_ancestor_or_self "$codex_worktrees" "$canonical"; then
      echo "error: project $project_id canonicalPath is under $codex_worktrees; Codex-owned worktree roots cannot be canonical project paths" >&2
      return 1
    fi
  fi

  git -C "$canonical" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "error: project $project_id canonicalPath is not a git work tree: $canonical" >&2
    return 1
  }
  toplevel=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
  toplevel_real=$(real_existing_dir "$toplevel") || {
    echo "error: project $project_id git work tree root cannot be resolved for $canonical" >&2
    return 1
  }
  if [ "$toplevel_real" != "$canonical" ]; then
    echo "error: project $project_id canonicalPath must be the git work tree root: $canonical (root: $toplevel_real)" >&2
    return 1
  fi
  gitdir=$(git -C "$canonical" rev-parse --git-dir 2>/dev/null) || return 1
  common=$(git -C "$canonical" rev-parse --git-common-dir 2>/dev/null) || return 1
  gitdir_real=$(git_path_real "$canonical" "$gitdir") || {
    echo "error: project $project_id git dir cannot be resolved for $canonical" >&2
    return 1
  }
  common_real=$(git_path_real "$canonical" "$common") || {
    echo "error: project $project_id git common dir cannot be resolved for $canonical" >&2
    return 1
  }
  if [ "$gitdir_real" != "$common_real" ]; then
    echo "error: project $project_id canonicalPath is a linked git worktree; linked git worktree cannot be a canonical project path" >&2
    return 1
  fi
  if [ -n "$expected_common" ]; then
    expected_common=$(real_existing_dir "$expected_common") || {
      echo "error: project $project_id gitCommonDir cannot be resolved: $expected_common" >&2
      return 1
    }
    if [ "$expected_common" != "$common_real" ]; then
      echo "error: project $project_id gitCommonDir mismatch: expected $expected_common, actual $common_real" >&2
      return 1
    fi
  fi
  printf '%s\n' "$common_real"
}

json_required_string() {
  local project=$1 project_id=$2 key=$3 label=$4 value
  value=$(printf '%s\n' "$project" | jq -r --arg key "$key" '
    if has($key) and (.[$key] | type == "string") then .[$key] else empty end
  ') || return 1
  [ -n "$value" ] || {
    if [ -n "$project_id" ]; then
      echo "error: project $project_id is missing required $label" >&2
    else
      echo "error: project registry entry is missing required $label" >&2
    fi
    return 1
  }
  printf '%s\n' "$value"
}

json_required_yolo() {
  local project=$1 project_id=$2 yolo_type yolo_value
  if ! printf '%s\n' "$project" | jq -e 'has("yolo")' >/dev/null; then
    echo "error: project $project_id is missing required yolo" >&2
    return 1
  fi
  yolo_type=$(printf '%s\n' "$project" | jq -r '.yolo | type') || return 1
  yolo_value=$(printf '%s\n' "$project" | jq -r '.yolo') || return 1
  case "$yolo_type:$yolo_value" in
    boolean:true|string:on|string:true) echo "on" ;;
    boolean:false|string:off|string:false) echo "off" ;;
    *)
      echo "error: project $project_id has invalid yolo: $yolo_value" >&2
      return 1
      ;;
  esac
}

validate_base_ref() {
  local project_id=$1 default_branch=$2 base_ref=$3
  if ! git check-ref-format --branch "$default_branch" >/dev/null 2>&1; then
    echo "error: project $project_id has invalid defaultBranch: $default_branch" >&2
    return 1
  fi
  case "$base_ref" in
    "refs/remotes/origin/$default_branch"|"origin/$default_branch"|"refs/heads/$default_branch")
      return 0
      ;;
    refs/remotes/origin/*|origin/*|refs/heads/*)
      echo "error: project $project_id baseRef must name defaultBranch $default_branch: $base_ref" >&2
      return 1
      ;;
    *)
      echo "error: project $project_id has unsupported baseRef: $base_ref" >&2
      return 1
      ;;
  esac
}

resolve_json() {
  local arg=$1 project status
  if project=$(json_registry_project "$arg"); then
    :
  else
    status=$?
    case "$status" in
      1) return 3 ;;
      *) return "$status" ;;
    esac
  fi
  [ -n "$project" ] || return 3

  normalize_json_project "$project"
}

normalize_json_project() {
  local project=$1 raw project_id canonical expected_common common default_branch base_ref mode yolo worktree_policy origin fork
  project_id=$(json_required_string "$project" "" projectId projectId) || return 1
  canonical=$(json_required_string "$project" "$project_id" canonicalPath canonicalPath) || return 1
  expected_common=$(printf '%s\n' "$project" | jq -r '.gitCommonDir // empty')
  default_branch=$(json_required_string "$project" "$project_id" defaultBranch defaultBranch) || return 1
  base_ref=$(json_required_string "$project" "$project_id" baseRef baseRef) || return 1
  mode=$(json_required_string "$project" "$project_id" mode mode) || return 1
  yolo=$(json_required_yolo "$project" "$project_id") || return 1
  worktree_policy=$(printf '%s\n' "$project" | jq -r '.worktreePolicy // "firstmate-owned"')
  origin=$(printf '%s\n' "$project" | jq -r '.remotes.origin // empty')
  fork=$(printf '%s\n' "$project" | jq -r '.remotes.fork // empty')
  validate_base_ref "$project_id" "$default_branch" "$base_ref" || return 1

  case "$canonical" in
    /*) ;;
    *) echo "error: project $project_id canonicalPath must be absolute: $canonical" >&2; return 1 ;;
  esac
  canonical=$(real_existing_dir "$canonical") || {
    echo "error: project $project_id canonicalPath is not a directory: $canonical" >&2
    return 1
  }
  common=$(validate_canonical_path "$project_id" "$canonical" "$expected_common") || return 1
  case "$mode" in
    no-mistakes|direct-PR|local-only) ;;
    *) echo "error: project $project_id has invalid mode: $mode" >&2; return 1 ;;
  esac

  raw=$(jq -n \
    --arg project_id "$project_id" \
    --arg canonical_path "$canonical" \
    --arg git_common_dir "$common" \
    --arg origin "$origin" \
    --arg fork "$fork" \
    --arg default_branch "$default_branch" \
    --arg base_ref "$base_ref" \
    --arg mode "$mode" \
    --arg yolo "$yolo" \
    --arg worktree_policy "$worktree_policy" \
    '{
      project_id: $project_id,
      canonical_path: $canonical_path,
      git_common_dir: $git_common_dir,
      origin: $origin,
      fork: $fork,
      default_branch: $default_branch,
      base_ref: $base_ref,
      mode: $mode,
      yolo: $yolo,
      worktree_policy: $worktree_policy,
      source: "json"
    }')
  printf '%s\n' "$raw"
}

resolve_fallback() {
  local arg=$1 project_id canonical mode_yolo mode yolo default_branch base_ref common
  project_id=$(fallback_project_id "$arg")
  canonical=$(fallback_project_path "$arg")
  mode_yolo=$(markdown_mode_yolo "$project_id")
  mode=${mode_yolo%% *}
  yolo=${mode_yolo##* }
  default_branch=$(fallback_default_branch "$canonical" || true)
  base_ref=
  [ -z "$default_branch" ] || base_ref="refs/remotes/origin/$default_branch"
  common=
  if [ -d "$canonical" ] && git -C "$canonical" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    common=$(git -C "$canonical" rev-parse --git-common-dir 2>/dev/null || true)
    if [ -n "$common" ]; then
      common=$(git_path_real "$canonical" "$common" 2>/dev/null || true)
    fi
  fi
  jq -n \
    --arg project_id "$project_id" \
    --arg canonical_path "$canonical" \
    --arg git_common_dir "$common" \
    --arg default_branch "$default_branch" \
    --arg base_ref "$base_ref" \
    --arg mode "$mode" \
    --arg yolo "$yolo" \
    '{
      project_id: $project_id,
      canonical_path: $canonical_path,
      git_common_dir: $git_common_dir,
      origin: "",
      fork: "",
      default_branch: $default_branch,
      base_ref: $base_ref,
      mode: $mode,
      yolo: $yolo,
      worktree_policy: "firstmate-owned",
      source: "legacy"
    }'
}

resolve_project() {
  local arg=$1 resolved status
  if [ -f "$JSON_REG" ]; then
    set +e
    resolved=$(resolve_json "$arg")
    status=$?
    set -e
    case "$status" in
      0) printf '%s\n' "$resolved"; return 0 ;;
      3) ;;
      *) return "$status" ;;
    esac
  fi
  resolve_fallback "$arg"
}

emit_shell() {
  local json=$1 key value
  for key in project_id canonical_path git_common_dir origin fork default_branch base_ref mode yolo worktree_policy source; do
    value=$(printf '%s\n' "$json" | jq -r --arg key "$key" '.[$key] // empty')
    printf 'fm_project_%s=%s\n' "$key" "$(shell_quote "$value")"
  done
}

list_projects() {
  local id path proj seen_ids seen_paths entry entries json_lines
  seen_ids=
  seen_paths=
  json_lines=
  if [ -f "$JSON_REG" ]; then
    command -v jq >/dev/null 2>&1 || {
      echo "error: $JSON_REG exists but jq is not installed" >&2
      return 1
    }
    entries=$(jq -c '.projects[]?' "$JSON_REG") || return 1
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      id=$(json_required_string "$entry" "" projectId projectId) || return 1
      [ -n "$id" ] || continue
      if printf '%s\n' "$seen_ids" | grep -Fxq -- "$id"; then
        echo "error: duplicate projectId in $JSON_REG: $id" >&2
        return 1
      fi
      proj=$(normalize_json_project "$entry") || return 1
      path=$(printf '%s\n' "$proj" | jq -r '.canonical_path')
      if printf '%s\n' "$seen_paths" | grep -Fxq -- "$path"; then
        echo "error: duplicate canonicalPath in $JSON_REG: $path" >&2
        return 1
      fi
      json_lines="${json_lines}${json_lines:+
}$id	$path"
      seen_ids="${seen_ids}${seen_ids:+
}$id"
      seen_paths="${seen_paths}${seen_paths:+
}$path"
    done <<EOF
$entries
EOF
    if [ -n "$json_lines" ]; then
      printf '%s\n' "$json_lines"
    fi
  fi
  [ -d "$PROJECTS" ] || return 0
  for path in "$PROJECTS"/*; do
    [ -e "$path" ] || continue
    [ -d "$path" ] || continue
    id=$(basename "$path")
    path=$(real_existing_dir "$path")
    if printf '%s\n' "$seen_ids" | grep -Fxq -- "$id"; then
      continue
    fi
    if printf '%s\n' "$seen_paths" | grep -Fxq -- "$path"; then
      continue
    fi
    printf '%s\t%s\n' "$id" "$path"
  done
}

OUTPUT=json
FIELD=
case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --json)
    OUTPUT=json
    shift
    ;;
  --shell)
    OUTPUT=shell
    shift
    ;;
  --field)
    [ $# -ge 2 ] || { usage; exit 1; }
    OUTPUT=field
    FIELD=$2
    shift 2
    ;;
  --list)
    [ $# -eq 1 ] || { usage; exit 1; }
    list_projects
    exit 0
    ;;
esac

[ $# -eq 1 ] || { usage; exit 1; }

json=$(resolve_project "$1")
case "$OUTPUT" in
  json)
    printf '%s\n' "$json"
    ;;
  shell)
    emit_shell "$json"
    ;;
  field)
    case "$FIELD" in
      project_id|canonical_path|git_common_dir|origin|fork|default_branch|base_ref|mode|yolo|worktree_policy|source) ;;
      *) echo "error: unknown project field: $FIELD" >&2; exit 1 ;;
    esac
    printf '%s\n' "$json" | jq -r --arg key "$FIELD" '.[$key] // empty'
    ;;
esac
