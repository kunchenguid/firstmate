#!/usr/bin/env bash
# Ensure a registered Firstmate project checkout has exactly one Paseo project.
# Usage: fm-paseo-project.sh [--if-selected] <project-name>
# --if-selected skips creation unless Paseo resolves as the runtime backend for new tasks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
ONLY_IF_SELECTED=0

usage() {
  echo "usage: fm-paseo-project.sh [--if-selected] <project-name>" >&2
}

if [ "${1:-}" = --if-selected ]; then
  ONLY_IF_SELECTED=1
  shift
fi
[ "$#" -eq 1 ] || { usage; exit 2; }
PROJECT_NAME=$1
case "$PROJECT_NAME" in
  ''|.|..|*/*)
    echo "error: project name must be one directory name" >&2
    exit 1
    ;;
esac

if [ "$ONLY_IF_SELECTED" -eq 1 ]; then
  # shellcheck source=bin/fm-backend.sh
  . "$FM_ROOT/bin/fm-backend.sh"
  backend=$(fm_backend_name)
  fm_backend_validate_spawn "$backend"
  if [ "$backend" != paseo ]; then
    printf 'skip: runtime backend for new tasks is %s; no Paseo project was created\n' "$backend"
    exit 0
  fi
fi

registry="$DATA/projects.md"
[ -r "$registry" ] || {
  printf 'error: project %s is not registered; registry is missing at %s\n' "$PROJECT_NAME" "$registry" >&2
  exit 1
}
registry_matches=$(PROJECT_NAME="$PROJECT_NAME" awk '$1 == "-" && $2 == ENVIRON["PROJECT_NAME"] { count++ } END { print count + 0 }' "$registry")
if [ "$registry_matches" -eq 0 ]; then
  printf 'error: project %s is not registered in %s\n' "$PROJECT_NAME" "$registry" >&2
  exit 1
fi
if [ "$registry_matches" -ne 1 ]; then
  printf 'error: project %s must have exactly one entry in %s (found %s)\n' \
    "$PROJECT_NAME" "$registry" "$registry_matches" >&2
  exit 1
fi

[ -d "$PROJECTS" ] || {
  printf 'error: Firstmate projects directory is missing at %s\n' "$PROJECTS" >&2
  exit 1
}
projects_real=$(cd -P -- "$PROJECTS" && pwd -P) || {
  printf 'error: cannot resolve Firstmate projects directory %s\n' "$PROJECTS" >&2
  exit 1
}
project_dir="$PROJECTS/$PROJECT_NAME"
[ -d "$project_dir" ] || {
  printf 'error: registered project %s is missing at %s\n' "$PROJECT_NAME" "$project_dir" >&2
  exit 1
}
project_real=$(cd -P -- "$project_dir" && pwd -P) || {
  printf 'error: cannot resolve registered project directory %s\n' "$project_dir" >&2
  exit 1
}
case "$project_real" in
  "$projects_real"/*) ;;
  *)
    printf 'error: registered project %s resolves outside the active home projects directory: %s\n' \
      "$PROJECT_NAME" "$project_real" >&2
    exit 1
    ;;
esac

# shellcheck source=bin/backends/paseo.sh
. "$FM_ROOT/bin/backends/paseo.sh"
fm_backend_paseo_tool_check
project_record=''
lookup_status=0
project_record=$(fm_backend_paseo_project_for_source "$project_real" --allow-missing) || lookup_status=$?
case "$lookup_status" in
  0)
    IFS=$'\t' read -r paseo_id paseo_name <<< "$project_record"
    printf 'Paseo project %s (%s) already matches registered project %s at %s\n' \
      "$paseo_name" "$paseo_id" "$PROJECT_NAME" "$project_real"
    exit 0
    ;;
  2) ;;
  *) exit "$lookup_status" ;;
esac

create_output=''
if ! create_output=$(paseo project create --json "$project_real" 2>&1); then
  printf 'error: could not create a Paseo project for registered project %s at %s\n' \
    "$PROJECT_NAME" "$project_real" >&2
  printf '%s\n' "$create_output" >&2
  exit 1
fi
if ! project_record=$(fm_backend_paseo_project_for_source "$project_real"); then
  printf 'error: Paseo project create returned, but exactly one project could not be verified for %s at %s\n' \
    "$PROJECT_NAME" "$project_real" >&2
  [ -z "$create_output" ] || printf '%s\n' "$create_output" >&2
  exit 1
fi
IFS=$'\t' read -r paseo_id paseo_name <<< "$project_record"
printf 'created Paseo project %s (%s) for registered project %s at %s\n' \
  "$paseo_name" "$paseo_id" "$PROJECT_NAME" "$project_real"
