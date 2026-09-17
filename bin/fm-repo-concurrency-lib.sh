#!/usr/bin/env bash
# Shared identity and lease authority for one project Firstmate repository subtree.
# This file is sourced by spawn, teardown, seed, and bootstrap owners.

FM_REPO_SCOPE_HOME=
FM_REPO_SCOPE_PROJECT=
FM_REPO_SCOPE_REPO_ID=
FM_REPO_SCOPE_AUTHORITY_ID=
FM_REPO_SCOPE_LOCK=
FM_REPO_SCOPE_LOCK_HELD=0
FM_REPO_SCOPE_LEASE_KEY=
FM_REPO_SCOPE_LEASE_CREATED=0
FM_REPO_SCOPE_LAST_ERROR=
FM_REPO_SCOPE_LEASE_AUTHORITY_ID=
FM_REPO_SCOPE_LEASE_REPO_ID=
FM_REPO_SCOPE_LEASE_TASK_HOME=
FM_REPO_SCOPE_LEASE_TASK_ID=
FM_REPO_SCOPE_ROOT_LOCK=
FM_REPO_SCOPE_ROOT_LOCK_HELD=0

fm_repo_scope_hash() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    echo "error: SHA-256 utility is required for repository authority identity" >&2
    return 1
  fi
}

fm_repo_scope_link_count() {  # <file>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_repo_scope_clone_identity() {  # <git-repository>
  local repo=$1 origin
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  fm_repo_scope_hash "$origin"
}

fm_repo_scope_canonical_origin() {  # <git-repository>
  local repo=$1 origin scheme rest host path prefix canonical_path source_path
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  case "$origin" in
    file://*)
      path=${origin#file://}
      case "$path" in localhost/*) path=${path#localhost} ;; esac
      case "$path" in
        /*) ;;
        *) path="/$path" ;;
      esac
      canonical_path=$(cd "$(dirname "$path")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$path")") || return 1
      printf 'file:%s\n' "$canonical_path"
      ;;
    *://*)
      scheme=${origin%%://*}
      rest=${origin#*://}
      host=${rest%%/*}
      path=${rest#*/}
      case "$host" in *@*) host=${host##*@} ;; esac
      [ -n "$path" ] && [ "$path" != "$rest" ] || return 1
      host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
      path=${path%/}
      path=${path%.git}
      case "$scheme" in
        http|https|ssh|git) printf 'host:%s/%s\n' "$host" "$path" ;;
        *) printf 'url:%s\n' "$origin" ;;
      esac
      ;;
    *)
      prefix=${origin%%:*}
      if [ "$prefix" != "$origin" ] && [[ "$prefix" != */* ]]; then
        host=$(printf '%s' "$prefix" | sed -E 's/^.*@//' | tr '[:upper:]' '[:lower:]')
        path=${origin#*:}
        path=${path#/}
        path=${path%/}
        path=${path%.git}
        [ -n "$host" ] && [ -n "$path" ] || return 1
        printf 'host:%s/%s\n' "$host" "$path"
      else
        case "$origin" in /*) source_path=$origin ;; *) source_path="$repo/$origin" ;; esac
        if [ -d "$source_path" ]; then
          canonical_path=$(cd "$source_path" && pwd -P) || return 1
        else
          canonical_path=$(cd "$(dirname "$source_path")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$source_path")") || return 1
        fi
        printf 'file:%s\n' "$canonical_path"
      fi
      ;;
  esac
}

fm_repo_scope_canonical_origin_identity() {  # <git-repository>
  local canonical
  canonical=$(fm_repo_scope_canonical_origin "$1") || return 1
  fm_repo_scope_hash "$canonical"
}

fm_repo_scope_root_route_lock_release() {
  [ "$FM_REPO_SCOPE_ROOT_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$FM_REPO_SCOPE_ROOT_LOCK"
  FM_REPO_SCOPE_ROOT_LOCK_HELD=0
}

fm_repo_scope_root_route_guard() {  # <task-home> <project-path>
  local task_home=$1 project_path=$2 authority_status root_home parent_file registry line entry_id entry_home entry_projects
  local target_identity entry_identity matched_id matched_home projects_list project
  FM_REPO_SCOPE_LAST_ERROR=
  if fm_repo_scope_authority_for_home "$task_home"; then
    return 0
  else
    authority_status=$?
    [ "$authority_status" -eq 1 ] || return 1
  fi
  if [ -f "$task_home/.fm-secondmate-home" ] || [ -L "$task_home/.fm-secondmate-home" ]; then
    parent_file="$task_home/.fm-secondmate-parent"
    # shellcheck source=bin/fm-secondmate-parent-lib.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-parent-lib.sh"
    fm_secondmate_parent_record_parse "$parent_file" || return 0
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] &&
      { [ -z "$FM_SECONDMATE_PARENT_ROLE" ] || [ "$FM_SECONDMATE_PARENT_ROLE" = root ]; } || return 0
    root_home=$(cd "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || return 0
  else
    root_home=$(cd "$task_home" 2>/dev/null && pwd -P) || return 0
  fi
  if [ -e "$root_home/.fm-project-firstmate" ] || [ -L "$root_home/.fm-project-firstmate" ] ||
    [ -e "$root_home/.fm-secondmate-home" ] || [ -L "$root_home/.fm-secondmate-home" ]; then
    return 0
  fi
  local root_data="$root_home/data" root_state="$root_home/state"
  if [ "$root_home" = "$(cd "${FM_HOME:-$root_home}" 2>/dev/null && pwd -P)" ]; then
    root_data=${FM_DATA_OVERRIDE:-$root_data}
    root_state=${FM_STATE_OVERRIDE:-$root_state}
  fi
  registry="$root_data/secondmates.md"
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"
  FM_REPO_SCOPE_ROOT_LOCK=$(secondmate_registry_lock_path "$root_state")
  fm_lock_acquire_wait "$FM_REPO_SCOPE_ROOT_LOCK" || {
    FM_REPO_SCOPE_LAST_ERROR="could not serialize repository routing with the root secondmate registry"
    return 1
  }
  FM_REPO_SCOPE_ROOT_LOCK_HELD=1
  [ -e "$registry" ] || [ -L "$registry" ] || return 0
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key || {
    FM_REPO_SCOPE_LAST_ERROR="root secondmate registry is unsafe while routing repository work: $SECONDMATE_REGISTRY_ERROR"
    fm_repo_scope_root_route_lock_release || true
    return 1
  }
  target_identity=$(fm_repo_scope_canonical_origin_identity "$project_path") || {
    FM_REPO_SCOPE_LAST_ERROR="cannot establish the canonical origin identity for $project_path"
    fm_repo_scope_root_route_lock_release || true
    return 1
  }
  matched_id=
  matched_home=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || {
      FM_REPO_SCOPE_LAST_ERROR="root secondmate registry contains an invalid route while checking repository ownership"
      fm_repo_scope_root_route_lock_release || true
      return 1
    }
    entry_id=$SECONDMATE_REGISTRY_ID
    entry_home=$SECONDMATE_REGISTRY_HOME
    entry_projects=$SECONDMATE_REGISTRY_PROJECTS
    if [ -e "$entry_home/.fm-project-firstmate" ] || [ -L "$entry_home/.fm-project-firstmate" ]; then
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || {
        FM_REPO_SCOPE_LAST_ERROR="project Firstmate $entry_id has a remote route that cannot be verified locally"
        fm_repo_scope_root_route_lock_release || true
        return 1
      }
      fm_repo_scope_marker_parse "$entry_home" || {
        FM_REPO_SCOPE_LAST_ERROR="registered project Firstmate $entry_id has an invalid authority marker"
        fm_repo_scope_root_route_lock_release || true
        return 1
      }
      entry_identity=$(fm_repo_scope_canonical_origin_identity "$entry_home/projects/$FM_REPO_SCOPE_PROJECT") || {
        FM_REPO_SCOPE_LAST_ERROR="cannot verify the repository identity of project Firstmate $entry_id"
        fm_repo_scope_root_route_lock_release || true
        return 1
      }
      if [ "$entry_identity" = "$target_identity" ]; then
        matched_id=$entry_id
        matched_home=$entry_home
      fi
    else
      projects_list=", $entry_projects, "
      case "$projects_list" in *", $(basename "$project_path"), "*) ;; *) continue ;; esac
    fi
  done < "$registry"
  if [ -n "$matched_id" ]; then
    FM_REPO_SCOPE_LAST_ERROR="repository $(basename "$project_path") is owned by project Firstmate $matched_id at $matched_home; route this work through that authority instead of spawning it from this home"
    fm_repo_scope_root_route_lock_release || true
    return 2
  fi
}

fm_repo_scope_marker_parse() {  # <project-firstmate-home>
  local home=$1 file line schema='' project='' repo_id='' authority_id='' repo_path='' home_real expected_authority
  local schema_count=0 project_count=0 repo_count=0 authority_count=0 path_count=0
  file="$home/.fm-project-firstmate"
  FM_REPO_SCOPE_HOME=
  FM_REPO_SCOPE_PROJECT=
  FM_REPO_SCOPE_REPO_ID=
  FM_REPO_SCOPE_AUTHORITY_ID=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*) schema_count=$((schema_count + 1)); schema=${line#schema=} ;;
      project=*) project_count=$((project_count + 1)); project=${line#project=} ;;
      repo_identity=*) repo_count=$((repo_count + 1)); repo_id=${line#repo_identity=} ;;
      authority_id=*) authority_count=$((authority_count + 1)); authority_id=${line#authority_id=} ;;
      repo_path=*) path_count=$((path_count + 1)); repo_path=${line#repo_path=} ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$schema_count" -eq 1 ] && [ "$schema" = fm-project-firstmate.v1 ] || return 1
  [ "$project_count" -eq 1 ] && [ "$repo_count" -eq 1 ] && [ "$authority_count" -eq 1 ] && [ "$path_count" -eq 1 ] || return 1
  case "$project" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [[ "$repo_id" =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
  [[ "$authority_id" =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
  case "$repo_path" in /*) ;; *) return 1 ;; esac
  home_real=$(cd "$home" && pwd -P) || return 1
  expected_authority="sha256:$(fm_repo_scope_hash "$home_real\n$project\n$repo_id")" || return 1
  [ "$authority_id" = "$expected_authority" ] || return 1
  FM_REPO_SCOPE_HOME=$home_real
  FM_REPO_SCOPE_PROJECT=$project
  FM_REPO_SCOPE_REPO_ID=$repo_id
  FM_REPO_SCOPE_AUTHORITY_ID=$authority_id
}

fm_repo_scope_authority_for_home() {  # <task-home>
  local home=$1 parent_file recorded_parent recorded_home recorded_authority recorded_repo
  FM_REPO_SCOPE_HOME=
  FM_REPO_SCOPE_PROJECT=
  FM_REPO_SCOPE_REPO_ID=
  FM_REPO_SCOPE_AUTHORITY_ID=
  FM_REPO_SCOPE_LAST_ERROR=
  if [ -f "$home/.fm-project-firstmate" ] || [ -L "$home/.fm-project-firstmate" ]; then
    if ! fm_repo_scope_marker_parse "$home"; then
      FM_REPO_SCOPE_LAST_ERROR="project Firstmate repository authority marker is invalid in $home"
      return 2
    fi
    return 0
  fi
  if [ ! -f "$home/.fm-secondmate-home" ]; then
    return 1
  fi
  parent_file="$home/.fm-secondmate-parent"
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-parent-lib.sh"
  if ! fm_secondmate_parent_record_parse "$parent_file"; then
    FM_REPO_SCOPE_LAST_ERROR="secondmate parent authority binding is missing or invalid in $home"
    return 2
  fi
  [ "$FM_SECONDMATE_PARENT_ROLE" = project-firstmate ] || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || {
    FM_REPO_SCOPE_LAST_ERROR="remote secondmate descendants cannot join a local repository concurrency scope"
    return 2
  }
  recorded_home=${FM_SECONDMATE_PARENT_REPO_AUTHORITY_HOME:-}
  recorded_authority=${FM_SECONDMATE_PARENT_REPO_AUTHORITY_ID:-}
  recorded_repo=${FM_SECONDMATE_PARENT_REPO_IDENTITY:-}
  [ -n "$recorded_home" ] && [ -n "$recorded_authority" ] && [ -n "$recorded_repo" ] || {
    FM_REPO_SCOPE_LAST_ERROR="secondmate $home has no local repository authority binding"
    return 2
  }
  case "$recorded_home" in /*) ;; *) FM_REPO_SCOPE_LAST_ERROR="repository authority home is not absolute"; return 2 ;; esac
  if ! fm_repo_scope_marker_parse "$recorded_home"; then
    FM_REPO_SCOPE_LAST_ERROR="repository authority home is unavailable or invalid: $recorded_home"
    return 2
  fi
  [ "$FM_REPO_SCOPE_AUTHORITY_ID" = "$recorded_authority" ] && [ "$FM_REPO_SCOPE_REPO_ID" = "$recorded_repo" ] || {
    FM_REPO_SCOPE_LAST_ERROR="repository authority identity changed for secondmate $home"
    return 2
  }
  recorded_parent=$(cd "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || {
    FM_REPO_SCOPE_LAST_ERROR="project Firstmate parent home is unavailable for secondmate $home"
    return 2
  }
  [ "$recorded_parent" = "$FM_REPO_SCOPE_HOME" ] || {
    FM_REPO_SCOPE_LAST_ERROR="secondmate $home does not directly name its repository authority as its parent"
    return 2
  }
  FM_REPO_SCOPE_HOME=$(cd "$recorded_home" && pwd -P) || return 2
  return 0
}

fm_repo_scope_validate_project() {  # <task-home> <project-path>
  local task_home=$1 project_path=$2 repo_id project_name task_home_real project_real expected_project
  fm_repo_scope_authority_for_home "$task_home" || return $?
  project_name=$(basename "$project_path")
  [ "$project_name" = "$FM_REPO_SCOPE_PROJECT" ] || {
    FM_REPO_SCOPE_LAST_ERROR="task project $project_name is outside the owned repository $FM_REPO_SCOPE_PROJECT"
    return 2
  }
  [ -d "$project_path" ] || {
    FM_REPO_SCOPE_LAST_ERROR="owned repository clone is unavailable: $project_path"
    return 2
  }
  task_home_real=$(cd "$task_home" 2>/dev/null && pwd -P) || {
    FM_REPO_SCOPE_LAST_ERROR="task home is unavailable: $task_home"
    return 2
  }
  [ ! -L "$task_home_real/projects" ] || {
    FM_REPO_SCOPE_LAST_ERROR="task home's projects directory must be a real directory: $task_home_real/projects"
    return 2
  }
  expected_project="$task_home_real/projects/$FM_REPO_SCOPE_PROJECT"
  [ ! -L "$expected_project" ] && [ -d "$expected_project" ] || {
    FM_REPO_SCOPE_LAST_ERROR="task home has no real owned repository clone at $expected_project"
    return 2
  }
  project_real=$(cd "$project_path" 2>/dev/null && pwd -P) || {
    FM_REPO_SCOPE_LAST_ERROR="owned repository clone is unavailable: $project_path"
    return 2
  }
  expected_project=$(cd "$expected_project" 2>/dev/null && pwd -P) || return 2
  [ "$project_real" = "$expected_project" ] || {
    FM_REPO_SCOPE_LAST_ERROR="task project path must be the task home's canonical owned clone at $expected_project"
    return 2
  }
  repo_id=$(fm_repo_scope_clone_identity "$project_path") || {
    FM_REPO_SCOPE_LAST_ERROR="owned repository clone has no readable origin identity: $project_path"
    return 2
  }
  [ "sha256:$repo_id" = "$FM_REPO_SCOPE_REPO_ID" ] || {
    FM_REPO_SCOPE_LAST_ERROR="project clone origin does not match the project's stable repository authority"
    return 2
  }
  return 0
}

fm_repo_scope_limit() {  # <authority-home>
  local config_dir=$1/config file=$1/config/repo-concurrency value links
  if [ -e "$config_dir" ] || [ -L "$config_dir" ]; then
    [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || {
      FM_REPO_SCOPE_LAST_ERROR="repository concurrency config directory is unsafe: $config_dir"
      return 1
    }
  else
    printf 'unlimited\n'
    return 0
  fi
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'unlimited\n'
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || {
    FM_REPO_SCOPE_LAST_ERROR="repository concurrency limit is unsafe: $file"
    return 1
  }
  links=$(fm_repo_scope_link_count "$file") || {
    FM_REPO_SCOPE_LAST_ERROR="cannot inspect repository concurrency limit link count: $file"
    return 1
  }
  [ "$links" = 1 ] || {
    FM_REPO_SCOPE_LAST_ERROR="repository concurrency limit is hardlinked: $file"
    return 1
  }
  value=$(<"$file") || {
    FM_REPO_SCOPE_LAST_ERROR="cannot read repository concurrency limit: $file"
    return 1
  }
  case "$value" in ''|*[!0-9]*|0|0*) FM_REPO_SCOPE_LAST_ERROR="repository concurrency limit must be a positive integer: $file"; return 1 ;; esac
  if ! printf '%s\n' "$value" | cmp -s "$file" -; then
    FM_REPO_SCOPE_LAST_ERROR="repository concurrency limit must contain exactly one value followed by one newline: $file"
    return 1
  fi
  [ "$value" -le 256 ] || {
    FM_REPO_SCOPE_LAST_ERROR="repository concurrency limit must not exceed 256: $file"
    return 1
  }
  printf '%s\n' "$value"
}

fm_repo_scope_lock_acquire() {  # <authority-home>
  local home=$1
  [ "$FM_REPO_SCOPE_LOCK_HELD" = 0 ] || return 0
  FM_REPO_SCOPE_LOCK="$home/state/.repo-concurrency.lock"
  fm_lock_acquire_wait "$FM_REPO_SCOPE_LOCK" || return 1
  FM_REPO_SCOPE_LOCK_HELD=1
}

fm_repo_scope_lock_release() {
  [ "$FM_REPO_SCOPE_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$FM_REPO_SCOPE_LOCK"
  FM_REPO_SCOPE_LOCK_HELD=0
}

fm_repo_scope_lease_key() {  # <task-home> <task-id>
  fm_repo_scope_hash "$(cd "$1" && pwd -P)\n$2"
}

fm_repo_scope_lease_path() {  # <authority-home> <task-home> <task-id>
  local key
  key=$(fm_repo_scope_lease_key "$2" "$3") || return 1
  printf '%s/state/.repo-concurrency/leases/%s.lease\n' "$1" "$key"
}

fm_repo_scope_lease_record_parse() {  # <lease-file>
  local file=$1 line schema='' authority='' repo='' task_home='' task_id=''
  local schema_count=0 authority_count=0 repo_count=0 home_count=0 id_count=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*) schema_count=$((schema_count + 1)); schema=${line#schema=} ;;
      authority_id=*) authority_count=$((authority_count + 1)); authority=${line#authority_id=} ;;
      repo_identity=*) repo_count=$((repo_count + 1)); repo=${line#repo_identity=} ;;
      task_home=*) home_count=$((home_count + 1)); task_home=${line#task_home=} ;;
      task_id=*) id_count=$((id_count + 1)); task_id=${line#task_id=} ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$schema_count" -eq 1 ] && [ "$schema" = fm-repo-concurrency-lease.v1 ] &&
    [ "$authority_count" -eq 1 ] && [ "$repo_count" -eq 1 ] &&
    [ "$home_count" -eq 1 ] && [ "$id_count" -eq 1 ] || return 1
  [[ "$authority" =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
  [[ "$repo" =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
  case "$task_home" in /*) ;; *) return 1 ;; esac
  case "$task_home" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  case "$task_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  FM_REPO_SCOPE_LEASE_AUTHORITY_ID=$authority
  FM_REPO_SCOPE_LEASE_REPO_ID=$repo
  FM_REPO_SCOPE_LEASE_TASK_HOME=$task_home
  FM_REPO_SCOPE_LEASE_TASK_ID=$task_id
}

fm_repo_scope_lease_identity_matches() {  # <lease-file> <authority-id> <repo-id> <task-home> <task-id>
  local file=$1 authority=$2 repo=$3 task_home=$4 task_id=$5
  fm_repo_scope_lease_record_parse "$file" || return 1
  [ "$FM_REPO_SCOPE_LEASE_AUTHORITY_ID" = "$authority" ] &&
    [ "$FM_REPO_SCOPE_LEASE_REPO_ID" = "$repo" ] &&
    [ "$FM_REPO_SCOPE_LEASE_TASK_HOME" = "$task_home" ] &&
    [ "$FM_REPO_SCOPE_LEASE_TASK_ID" = "$task_id" ]
}

fm_repo_scope_remove_lease_locked() {  # <task-home> <task-id>
  local task_home=$1 task_id=$2 lease key
  lease=$(fm_repo_scope_lease_path "$FM_REPO_SCOPE_HOME" "$task_home" "$task_id") || return 1
  [ -e "$lease" ] || [ -L "$lease" ] || return 0
  key=$(fm_repo_scope_lease_key "$task_home" "$task_id") || return 1
  fm_repo_scope_lease_identity_matches "$lease" "$FM_REPO_SCOPE_AUTHORITY_ID" "$FM_REPO_SCOPE_REPO_ID" "$task_home" "$task_id" || {
    FM_REPO_SCOPE_LAST_ERROR="repository concurrency lease identity is invalid: $lease"
    return 1
  }
  rm -f -- "$lease"
  FM_REPO_SCOPE_LEASE_KEY=$key
}

fm_repo_scope_count_leases_locked() {  # <authority-home>
  local dir=$1/state/.repo-concurrency/leases lease count=0
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  for lease in "$dir"/*.lease; do
    [ -e "$lease" ] || [ -L "$lease" ] || continue
    [ ! -L "$lease" ] || { FM_REPO_SCOPE_LAST_ERROR="repository concurrency lease is a symlink: $lease"; return 1; }
    # Lease records are trusted only after their schema and authority identity match.
    if ! fm_repo_scope_lease_record_parse "$lease" ||
      [ "$FM_REPO_SCOPE_LEASE_AUTHORITY_ID" != "$FM_REPO_SCOPE_AUTHORITY_ID" ] ||
      [ "$FM_REPO_SCOPE_LEASE_REPO_ID" != "$FM_REPO_SCOPE_REPO_ID" ]; then
      FM_REPO_SCOPE_LAST_ERROR="repository concurrency lease is malformed or belongs to another authority: $lease"
      return 1
    fi
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

fm_repo_scope_meta_value() {  # <meta-file> <key>
  local file=$1 key=$2 line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*) value=${line#*=} ;; esac
  done < "$file" 2>/dev/null || true
  printf '%s' "$value"
}

fm_repo_scope_reconcile_home_locked() {  # <project-firstmate-home> [report:0|1]
  (
    local home=$1 report=${2:-0} script_dir registry tmp homes expected expected_paths task_home state_dir meta task_id kind project_path expected_project lease lease_dir limit count available line task_home_real task_project_real file
    set -u
    fm_repo_scope_marker_parse "$home" || {
      echo "error: cannot reconcile an invalid project Firstmate authority at $home" >&2
      exit 1
    }
    [ -d "$home/state" ] && [ ! -L "$home/state" ] || {
      echo "error: project Firstmate state directory is missing or unsafe: $home/state" >&2
      exit 1
    }
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$script_dir/fm-secondmate-registry-lib.sh"
    # shellcheck source=bin/fm-secondmate-parent-lib.sh
    . "$script_dir/fm-secondmate-parent-lib.sh"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-repo-scope-reconcile.XXXXXX") || {
      echo "error: cannot allocate repository concurrency repair state" >&2
      exit 1
    }
    homes="$tmp/homes"
    expected="$tmp/expected"
    expected_paths="$tmp/expected-paths"
    : > "$expected"
    : > "$expected_paths"
    home=$(cd "$home" && pwd -P) || { rm -rf -- "$tmp"; exit 1; }
    printf '%s\n' "$home" > "$homes"
    registry="$home/data/secondmates.md"
    if [ -e "$registry" ] || [ -L "$registry" ]; then
      secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key || {
        echo "error: cannot reconcile project Firstmate children: $SECONDMATE_REGISTRY_ERROR" >&2
        rm -rf -- "$tmp"
        exit 1
      }
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "- "*) ;; *) continue ;; esac
        secondmate_registry_parse_line "$line" || {
          echo "error: malformed project Firstmate child route: $line" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || {
          echo "error: remote descendants beneath a project Firstmate are unsupported until distributed repository locking exists" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        task_home=$(secondmate_registry_path_key "$SECONDMATE_REGISTRY_HOME") || {
          echo "error: cannot resolve local child home for $SECONDMATE_REGISTRY_ID" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        [ -f "$task_home/.fm-secondmate-home" ] && [ ! -L "$task_home/.fm-secondmate-home" ] || {
          echo "error: project Firstmate child $SECONDMATE_REGISTRY_ID is not a seeded ordinary secondmate home" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        fm_secondmate_parent_record_parse "$task_home/.fm-secondmate-parent" || {
          echo "error: project Firstmate child $SECONDMATE_REGISTRY_ID has an invalid parent binding" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] &&
          [ "$FM_SECONDMATE_PARENT_ROLE" = project-firstmate ] &&
          [ "$FM_SECONDMATE_PARENT_HOME" = "$home" ] &&
          [ "$FM_SECONDMATE_PARENT_REPO_AUTHORITY_HOME" = "$home" ] &&
          [ "$FM_SECONDMATE_PARENT_REPO_AUTHORITY_ID" = "$FM_REPO_SCOPE_AUTHORITY_ID" ] &&
          [ "$FM_SECONDMATE_PARENT_REPO_IDENTITY" = "$FM_REPO_SCOPE_REPO_ID" ] || {
          echo "error: project Firstmate child $SECONDMATE_REGISTRY_ID is not bound to this local repository authority" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        printf '%s\n' "$task_home" >> "$homes"
      done < "$registry"
    fi
    while IFS= read -r task_home; do
      state_dir="$task_home/state"
      if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then
        [ "$task_home" = "$home" ] || continue
        echo "error: project Firstmate state directory is missing: $state_dir" >&2
        rm -rf -- "$tmp"
        exit 1
      fi
      [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || {
        echo "error: repository concurrency task state directory is unsafe: $state_dir" >&2
        rm -rf -- "$tmp"
        exit 1
      }
      for meta in "$state_dir"/*.meta; do
        [ -e "$meta" ] || [ -L "$meta" ] || continue
        [ -f "$meta" ] && [ ! -L "$meta" ] || {
          echo "error: repository concurrency task record is unsafe: $meta" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        task_id=$(basename "$meta" .meta)
        kind=$(fm_repo_scope_meta_value "$meta" kind)
        [ -n "$kind" ] || kind=ship
        case "$kind" in
          secondmate) continue ;;
          ship|scout) ;;
          *) echo "error: repository concurrency task $task_id has an unknown kind: $kind" >&2; rm -rf -- "$tmp"; exit 1 ;;
        esac
        case "$task_id" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe repository concurrency task id in $meta" >&2; rm -rf -- "$tmp"; exit 1 ;; esac
        project_path=$(fm_repo_scope_meta_value "$meta" project)
        [ -n "$project_path" ] || { echo "error: repository concurrency task $task_id has no project path" >&2; rm -rf -- "$tmp"; exit 1; }
        fm_repo_scope_validate_project "$task_home" "$project_path" || {
          echo "error: cannot reconcile repository concurrency task $task_id: $FM_REPO_SCOPE_LAST_ERROR" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        task_home_real=$(cd "$task_home" && pwd -P) || { rm -rf -- "$tmp"; exit 1; }
        task_project_real=$(cd "$project_path" && pwd -P) || { rm -rf -- "$tmp"; exit 1; }
        expected_project=$(cd "$task_home/projects/$FM_REPO_SCOPE_PROJECT" 2>/dev/null && pwd -P) || {
          echo "error: repository concurrency task $task_id has no owned project clone in $task_home/projects" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        [ "$task_project_real" = "$expected_project" ] || {
          echo "error: repository concurrency task $task_id points outside its home-owned project clone" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        lease=$(fm_repo_scope_lease_path "$home" "$task_home_real" "$task_id") || { rm -rf -- "$tmp"; exit 1; }
        printf '%s\t%s\t%s\t%s\n' "$lease" "$task_home_real" "$task_id" "$project_path" >> "$expected"
        printf '%s\n' "$lease" >> "$expected_paths"
      done
    done < "$homes"

    lease_dir="$home/state/.repo-concurrency/leases"
    if [ -e "$home/state/.repo-concurrency" ] || [ -L "$home/state/.repo-concurrency" ]; then
      [ -d "$home/state/.repo-concurrency" ] && [ ! -L "$home/state/.repo-concurrency" ] || {
        echo "error: repository concurrency lease directory is unsafe: $home/state/.repo-concurrency" >&2
        rm -rf -- "$tmp"
        exit 1
      }
    fi
    if [ -e "$lease_dir" ] || [ -L "$lease_dir" ]; then
      [ -d "$lease_dir" ] && [ ! -L "$lease_dir" ] || {
        echo "error: repository concurrency lease directory is unsafe: $lease_dir" >&2
        rm -rf -- "$tmp"
        exit 1
      }
      for lease in "$lease_dir"/*.lease; do
        [ -e "$lease" ] || [ -L "$lease" ] || continue
        [ ! -L "$lease" ] || { echo "error: repository concurrency lease is a symlink: $lease" >&2; rm -rf -- "$tmp"; exit 1; }
        fm_repo_scope_lease_record_parse "$lease" || {
          echo "error: repository concurrency lease is malformed: $lease" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        [ "$FM_REPO_SCOPE_LEASE_AUTHORITY_ID" = "$FM_REPO_SCOPE_AUTHORITY_ID" ] &&
          [ "$FM_REPO_SCOPE_LEASE_REPO_ID" = "$FM_REPO_SCOPE_REPO_ID" ] || {
          echo "error: repository concurrency lease belongs to a different authority: $lease" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        task_home_real=$(cd "$FM_REPO_SCOPE_LEASE_TASK_HOME" 2>/dev/null && pwd -P || true)
        [ -n "$task_home_real" ] || task_home_real=$FM_REPO_SCOPE_LEASE_TASK_HOME
        file=$(fm_repo_scope_lease_path "$home" "$task_home_real" "$FM_REPO_SCOPE_LEASE_TASK_ID") || { rm -rf -- "$tmp"; exit 1; }
        [ "$file" = "$lease" ] || {
          echo "error: repository concurrency lease is stored under the wrong stable identity: $lease" >&2
          rm -rf -- "$tmp"
          exit 1
        }
        if ! grep -Fqx -- "$lease" "$expected_paths"; then
          if grep -Fqx -- "$task_home_real" "$homes" || { [ ! -e "$task_home_real" ] && [ ! -L "$task_home_real" ]; }; then
            rm -f -- "$lease" || { echo "error: cannot remove stale repository concurrency lease: $lease" >&2; rm -rf -- "$tmp"; exit 1; }
          else
            echo "error: repository concurrency lease names an unregistered live task home: $task_home_real" >&2
            rm -rf -- "$tmp"
            exit 1
          fi
        fi
      done
    else
      mkdir -p "$lease_dir" || { echo "error: cannot create repository concurrency lease directory: $lease_dir" >&2; rm -rf -- "$tmp"; exit 1; }
    fi
    umask 077
    while IFS=$'\t' read -r lease task_home_real task_id project_path; do
      [ -n "$lease" ] || continue
      if [ ! -e "$lease" ] && [ ! -L "$lease" ]; then
        file="$lease.tmp.${BASHPID:-$$}"
        {
          printf 'schema=fm-repo-concurrency-lease.v1\n'
          printf 'authority_id=%s\n' "$FM_REPO_SCOPE_AUTHORITY_ID"
          printf 'repo_identity=%s\n' "$FM_REPO_SCOPE_REPO_ID"
          printf 'task_home=%s\n' "$task_home_real"
          printf 'task_id=%s\n' "$task_id"
        } > "$file" || { rm -rf -- "$tmp"; exit 1; }
        mv -f -- "$file" "$lease" || { rm -rf -- "$tmp"; exit 1; }
      else
        fm_repo_scope_lease_identity_matches "$lease" "$FM_REPO_SCOPE_AUTHORITY_ID" "$FM_REPO_SCOPE_REPO_ID" "$task_home_real" "$task_id" || {
          echo "error: repository concurrency lease does not match task record $task_id" >&2
          rm -rf -- "$tmp"
          exit 1
        }
      fi
    done < "$expected"
    limit=$(fm_repo_scope_limit "$home") || { echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2; rm -rf -- "$tmp"; exit 1; }
    count=$(fm_repo_scope_count_leases_locked "$home") || { echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2; rm -rf -- "$tmp"; exit 1; }
    if [ "$limit" = unlimited ]; then
      available=unlimited
    else
      available=$((limit - count))
      [ "$available" -ge 0 ] || available=0
    fi
    if [ "$report" = 1 ]; then
      printf 'REPO_CONCURRENCY: %s active=%s limit=%s available=%s\n' "$FM_REPO_SCOPE_PROJECT" "$count" "$limit" "$available"
    fi
    rm -rf -- "$tmp"
  )
}

fm_repo_scope_reconcile_task_home() {  # <project-firstmate-or-local-child-home>
  local task_home=$1 status authority_home
  if fm_repo_scope_authority_for_home "$task_home"; then
    authority_home=$FM_REPO_SCOPE_HOME
  else
    status=$?
    [ "$status" -eq 1 ] && return 0
    echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2
    return 1
  fi
  fm_repo_scope_lock_acquire "$authority_home" || return 1
  if fm_repo_scope_reconcile_home_locked "$authority_home" 1; then
    fm_repo_scope_lock_release
  else
    status=$?
    fm_repo_scope_lock_release || true
    return "$status"
  fi
}

fm_repo_scope_acquire_task() {  # <task-home> <task-id> <project-path> <relaunch:0|1>
  local task_home=$1 task_id=$2 project_path=$3 relaunch=$4 authority_status lease limit count task_home_real tmp authority_home
  FM_REPO_SCOPE_LEASE_CREATED=0
  FM_REPO_SCOPE_LEASE_KEY=
  if fm_repo_scope_validate_project "$task_home" "$project_path"; then
    :
  else
    authority_status=$?
    [ "$authority_status" -eq 1 ] && return 0
    echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2
    return 1
  fi
  authority_home=$FM_REPO_SCOPE_HOME
  limit=$(fm_repo_scope_limit "$authority_home") || { echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2; return 1; }
  fm_repo_scope_lock_acquire "$authority_home" || return 1
  fm_repo_scope_reconcile_home_locked "$authority_home" 0 || return 1
  limit=$(fm_repo_scope_limit "$authority_home") || { echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2; return 1; }
  task_home_real=$(cd "$task_home" && pwd -P) || return 1
  lease=$(fm_repo_scope_lease_path "$authority_home" "$task_home_real" "$task_id") || return 1
  FM_REPO_SCOPE_LEASE_KEY=${lease##*/}
  FM_REPO_SCOPE_LEASE_KEY=${FM_REPO_SCOPE_LEASE_KEY%.lease}
  if [ -e "$lease" ] || [ -L "$lease" ]; then
    if [ "$relaunch" = 1 ] && fm_repo_scope_lease_identity_matches "$lease" "$FM_REPO_SCOPE_AUTHORITY_ID" "$FM_REPO_SCOPE_REPO_ID" "$task_home_real" "$task_id"; then
      return 0
    fi
    FM_REPO_SCOPE_LAST_ERROR="repository concurrency lease already exists for task $task_id"
    return 1
  fi
  count=$(fm_repo_scope_count_leases_locked "$authority_home") || { echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2; return 1; }
  if [ "$relaunch" != 1 ] && [ "$limit" != unlimited ] && [ "$count" -ge "$limit" ]; then
    echo "queued: repository subtree has $count active ship/scout tasks at its configured limit of $limit" >&2
    return 2
  fi
  mkdir -p "$(dirname "$lease")" || return 1
  tmp="$lease.tmp.${BASHPID:-$$}"
  {
    printf 'schema=fm-repo-concurrency-lease.v1\n'
    printf 'authority_id=%s\n' "$FM_REPO_SCOPE_AUTHORITY_ID"
    printf 'repo_identity=%s\n' "$FM_REPO_SCOPE_REPO_ID"
    printf 'task_home=%s\n' "$task_home_real"
    printf 'task_id=%s\n' "$task_id"
  } > "$tmp" || return 1
  mv -f -- "$tmp" "$lease" || return 1
  FM_REPO_SCOPE_LEASE_CREATED=1
}

fm_repo_scope_release_task() {  # <task-home> <task-id>
  local task_home=$1 task_id=$2 authority_status lock_was_held=$FM_REPO_SCOPE_LOCK_HELD remove_status=0
  if fm_repo_scope_authority_for_home "$task_home"; then
    :
  else
    authority_status=$?
    [ "$authority_status" -eq 1 ] && return 0
    echo "error: $FM_REPO_SCOPE_LAST_ERROR" >&2
    return 1
  fi
  fm_repo_scope_lock_acquire "$FM_REPO_SCOPE_HOME" || return 1
  if fm_repo_scope_remove_lease_locked "$(cd "$task_home" && pwd -P)" "$task_id"; then
    remove_status=0
  else
    remove_status=$?
  fi
  if [ "$lock_was_held" = 0 ]; then
    fm_repo_scope_lock_release || remove_status=1
  fi
  return "$remove_status"
}

fm_repo_scope_release_task_if_bound() {  # <task-home> <task-id>
  local task_home=$1
  if [ -e "$task_home/.fm-project-firstmate" ] || [ -L "$task_home/.fm-project-firstmate" ] \
    || [ -e "$task_home/.fm-secondmate-parent" ] || [ -L "$task_home/.fm-secondmate-parent" ]; then
    fm_repo_scope_release_task "$task_home" "$2"
  fi
}
