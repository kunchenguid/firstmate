#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed record fields are output globals for sourcing callers.
# Guarded local-project route primitives shared by local secondmate seeding,
# branch return, and captain-controlled local landing.
#
# The private capability at data/local-project-routes/<secondmate>/<project>.route
# is the single durable binding between one main home project and one isolated
# project copy in a local secondmate home. It contains canonical filesystem and
# Git common-directory identities only. It never contains repository content,
# credentials, strategy, or a remote URL.
#
# Record schema (exactly one of every field; unknown fields are refused):
#   schema=fm-local-project-route.v1
#   secondmate_id=<safe id>
#   project=<safe flat project name>
#   main_home=<canonical absolute path>
#   main_project=<canonical absolute path>
#   main_git_common_dir=<canonical absolute path>
#   main_git_identity=<device:inode of that directory>
#   secondmate_home=<canonical absolute path>
#   secondmate_project=<canonical absolute path>
#   secondmate_git_common_dir=<canonical absolute path>
#   secondmate_git_identity=<device:inode of that directory>
#   anchor_oid=<seed-time commit that must remain in both repository lineages>
#
# A local project route accepts only filesystem transports: an absolute path or
# file:///absolute/path. Any configured fetch or push URL using another
# transport refuses the route. The secondmate copy must have exactly one remote,
# origin, whose fetch URL resolves to the bound main project and whose push URL
# resolves back to the secondmate copy itself, so ordinary origin pushes cannot
# write into the main project.

FM_LOCAL_ROUTE_ERROR=
FM_LOCAL_ROUTE_SECONDMATE_ID=
FM_LOCAL_ROUTE_PROJECT=
FM_LOCAL_ROUTE_MAIN_HOME=
FM_LOCAL_ROUTE_MAIN_PROJECT=
FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR=
FM_LOCAL_ROUTE_MAIN_GIT_IDENTITY=
FM_LOCAL_ROUTE_SECONDMATE_HOME=
FM_LOCAL_ROUTE_SECONDMATE_PROJECT=
FM_LOCAL_ROUTE_SECONDMATE_GIT_COMMON_DIR=
FM_LOCAL_ROUTE_SECONDMATE_GIT_IDENTITY=
FM_LOCAL_ROUTE_ANCHOR_OID=
FM_LOCAL_RETURN_TASK_ID=
FM_LOCAL_RETURN_BRANCH=
FM_LOCAL_RETURN_BASE_OID=
FM_LOCAL_RETURN_HEAD_OID=

fm_local_route_safe_id() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_local_route_capability_path() { # <main-home> <secondmate-id> <project>
  fm_local_route_safe_id "$2" && fm_local_route_safe_id "$3" || return 1
  printf '%s/data/local-project-routes/%s/%s.route\n' "$1" "$2" "$3"
}

fm_local_route_canonical_dir() { # <absolute directory>; refuses every symlink component
  local path=$1 canonical
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *[[:cntrl:]]*) return 1 ;; esac
  case "/$path/" in */../*|*/./*) return 1 ;; esac
  case "$path" in *'//'*) return 1 ;; esac
  [ -d "$path" ] || return 1
  canonical=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
  [ "$canonical" = "${path%/}" ] || return 1
  printf '%s\n' "$canonical"
}

fm_local_route_path_identity() { # <path>; portable device:inode
  if stat -f '%d:%i' "$1" >/dev/null 2>&1; then
    LC_ALL=C stat -f '%d:%i' "$1"
  else
    LC_ALL=C stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

fm_local_route_default_branch() { # <repository>; exactly one local main or master
  local repo=$1 branch found=''
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      [ -z "$found" ] || return 1
      found=$branch
    fi
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_local_route_git_common_dir() { # <canonical repository top-level>
  local repo=$1 top common
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(fm_local_route_canonical_dir "$top") || return 1
  [ "$top" = "$repo" ] || return 1
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  fm_local_route_canonical_dir "$common"
}

fm_local_route_url_path() { # <repo> <URL>; prints canonical local filesystem path
  local repo=$1 url=$2 path
  case "$url" in
    /*) path=$url ;;
    file:///*) path=${url#file://} ;;
    *) return 1 ;;
  esac
  fm_local_route_canonical_dir "$path"
}

fm_local_route_all_remotes_local() { # <repository> <label>
  local repo=$1 label=$2 remote url
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      if ! fm_local_route_url_path "$repo" "$url" >/dev/null 2>&1; then
        FM_LOCAL_ROUTE_ERROR="$label has a non-local remote; local-only secondmate routes accept only absolute filesystem or file:/// transports"
        return 1
      fi
    done < <({ git -C "$repo" remote get-url --all "$remote" 2>/dev/null || true; git -C "$repo" remote get-url --push --all "$remote" 2>/dev/null || true; } | awk '!seen[$0]++')
  done < <(git -C "$repo" remote 2>/dev/null)
}

fm_local_route_exact_origin() { # <secondmate-project> <bound-main-project>
  local repo=$1 expected=$2 remotes fetch_urls push_urls fetch_count push_count fetch_path push_path
  remotes=$(git -C "$repo" remote 2>/dev/null) || {
    FM_LOCAL_ROUTE_ERROR="secondmate project remotes are unreadable"
    return 1
  }
  [ "$remotes" = origin ] || {
    FM_LOCAL_ROUTE_ERROR="secondmate project must have exactly one local origin"
    return 1
  }
  fetch_urls=$(git -C "$repo" remote get-url --all origin 2>/dev/null) || {
    FM_LOCAL_ROUTE_ERROR="secondmate project must have exactly one local origin"
    return 1
  }
  push_urls=$(git -C "$repo" remote get-url --push --all origin 2>/dev/null) || {
    FM_LOCAL_ROUTE_ERROR="secondmate project must have exactly one local origin"
    return 1
  }
  fetch_count=$(printf '%s\n' "$fetch_urls" | awk 'NF { n++ } END { print n + 0 }')
  push_count=$(printf '%s\n' "$push_urls" | awk 'NF { n++ } END { print n + 0 }')
  [ "$fetch_count" -eq 1 ] && [ "$push_count" -eq 1 ] || {
    FM_LOCAL_ROUTE_ERROR="secondmate project must have exactly one local origin"
    return 1
  }
  fetch_path=$(fm_local_route_url_path "$repo" "$fetch_urls") || {
    FM_LOCAL_ROUTE_ERROR="secondmate project has a non-local remote"
    return 1
  }
  push_path=$(fm_local_route_url_path "$repo" "$push_urls") || {
    FM_LOCAL_ROUTE_ERROR="secondmate project has a non-local remote"
    return 1
  }
  [ "$fetch_path" = "$expected" ] && [ "$push_path" = "$repo" ] || {
    FM_LOCAL_ROUTE_ERROR="secondmate project origin does not match its guarded main-project route"
    return 1
  }
}

fm_local_route_record_load() { # <capability-file>
  local file=$1 line key value
  local schema='' secondmate_id='' project='' main_home='' main_project='' main_git='' main_git_identity=''
  local secondmate_home='' secondmate_project='' secondmate_git='' secondmate_git_identity='' anchor_oid=''
  local schema_n=0 secondmate_id_n=0 project_n=0 main_home_n=0 main_project_n=0 main_git_n=0 main_git_identity_n=0
  local secondmate_home_n=0 secondmate_project_n=0 secondmate_git_n=0 secondmate_git_identity_n=0 anchor_oid_n=0
  FM_LOCAL_ROUTE_ERROR=
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    FM_LOCAL_ROUTE_ERROR="local-project capability is unavailable or unsafe"
    return 1
  fi
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || {
    FM_LOCAL_ROUTE_ERROR="local-project capability is unavailable or unsafe"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || {
      FM_LOCAL_ROUTE_ERROR="local-project capability is malformed"
      return 1
    }
    case "$key" in
      schema) schema_n=$((schema_n + 1)); schema=$value ;;
      secondmate_id) secondmate_id_n=$((secondmate_id_n + 1)); secondmate_id=$value ;;
      project) project_n=$((project_n + 1)); project=$value ;;
      main_home) main_home_n=$((main_home_n + 1)); main_home=$value ;;
      main_project) main_project_n=$((main_project_n + 1)); main_project=$value ;;
      main_git_common_dir) main_git_n=$((main_git_n + 1)); main_git=$value ;;
      main_git_identity) main_git_identity_n=$((main_git_identity_n + 1)); main_git_identity=$value ;;
      secondmate_home) secondmate_home_n=$((secondmate_home_n + 1)); secondmate_home=$value ;;
      secondmate_project) secondmate_project_n=$((secondmate_project_n + 1)); secondmate_project=$value ;;
      secondmate_git_common_dir) secondmate_git_n=$((secondmate_git_n + 1)); secondmate_git=$value ;;
      secondmate_git_identity) secondmate_git_identity_n=$((secondmate_git_identity_n + 1)); secondmate_git_identity=$value ;;
      anchor_oid) anchor_oid_n=$((anchor_oid_n + 1)); anchor_oid=$value ;;
      *) FM_LOCAL_ROUTE_ERROR="local-project capability is malformed"; return 1 ;;
    esac
  done < "$file"
  [ "$schema_n" -eq 1 ] && [ "$secondmate_id_n" -eq 1 ] && [ "$project_n" -eq 1 ] \
    && [ "$main_home_n" -eq 1 ] && [ "$main_project_n" -eq 1 ] && [ "$main_git_n" -eq 1 ] \
    && [ "$main_git_identity_n" -eq 1 ] && [ "$secondmate_home_n" -eq 1 ] \
    && [ "$secondmate_project_n" -eq 1 ] && [ "$secondmate_git_n" -eq 1 ] \
    && [ "$secondmate_git_identity_n" -eq 1 ] && [ "$anchor_oid_n" -eq 1 ] || {
      FM_LOCAL_ROUTE_ERROR="local-project capability is malformed"
      return 1
    }
  [ "$schema" = fm-local-project-route.v1 ] \
    && fm_local_route_safe_id "$secondmate_id" \
    && fm_local_route_safe_id "$project" \
    && [[ "$anchor_oid" =~ ^[0-9a-f]{40,64}$ ]] || {
      FM_LOCAL_ROUTE_ERROR="local-project capability is malformed"
      return 1
    }
  for value in "$main_home" "$main_project" "$main_git" "$secondmate_home" "$secondmate_project" "$secondmate_git"; do
    case "$value" in /*) ;; *) FM_LOCAL_ROUTE_ERROR="local-project capability is malformed"; return 1 ;; esac
  done
  FM_LOCAL_ROUTE_SECONDMATE_ID=$secondmate_id
  FM_LOCAL_ROUTE_PROJECT=$project
  FM_LOCAL_ROUTE_MAIN_HOME=$main_home
  FM_LOCAL_ROUTE_MAIN_PROJECT=$main_project
  FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR=$main_git
  FM_LOCAL_ROUTE_MAIN_GIT_IDENTITY=$main_git_identity
  FM_LOCAL_ROUTE_SECONDMATE_HOME=$secondmate_home
  FM_LOCAL_ROUTE_SECONDMATE_PROJECT=$secondmate_project
  FM_LOCAL_ROUTE_SECONDMATE_GIT_COMMON_DIR=$secondmate_git
  FM_LOCAL_ROUTE_SECONDMATE_GIT_IDENTITY=$secondmate_git_identity
  FM_LOCAL_ROUTE_ANCHOR_OID=$anchor_oid
}

fm_local_route_record_write() { # <file> <secondmate-id> <project> <main-home> <main-project> <secondmate-home> <secondmate-project>
  local file=$1 id=$2 project=$3 main_home=$4 main_project=$5 secondmate_home=$6 secondmate_project=$7
  local main_git secondmate_git main_git_identity secondmate_git_identity anchor_oid default tmp
  main_git=$(fm_local_route_git_common_dir "$main_project") || return 1
  secondmate_git=$(fm_local_route_git_common_dir "$secondmate_project") || return 1
  [ "$main_git" = "$main_project/.git" ] && [ "$secondmate_git" = "$secondmate_project/.git" ] || return 1
  main_git_identity=$(fm_local_route_path_identity "$main_git") || return 1
  secondmate_git_identity=$(fm_local_route_path_identity "$secondmate_git") || return 1
  default=$(fm_local_route_default_branch "$main_project") || return 1
  anchor_oid=$(git -C "$main_project" rev-parse --verify "refs/heads/$default^{commit}" 2>/dev/null) || return 1
  git -C "$secondmate_project" cat-file -e "$anchor_oid^{commit}" 2>/dev/null || return 1
  mkdir -p "$(dirname "$file")" || return 1
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$(dirname "$file")/.route.XXXXXX") || return 1
  {
    printf 'schema=fm-local-project-route.v1\n'
    printf 'secondmate_id=%s\n' "$id"
    printf 'project=%s\n' "$project"
    printf 'main_home=%s\n' "$main_home"
    printf 'main_project=%s\n' "$main_project"
    printf 'main_git_common_dir=%s\n' "$main_git"
    printf 'main_git_identity=%s\n' "$main_git_identity"
    printf 'secondmate_home=%s\n' "$secondmate_home"
    printf 'secondmate_project=%s\n' "$secondmate_project"
    printf 'secondmate_git_common_dir=%s\n' "$secondmate_git"
    printf 'secondmate_git_identity=%s\n' "$secondmate_git_identity"
    printf 'anchor_oid=%s\n' "$anchor_oid"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

fm_local_route_validate_bound_copy() { # <capability> <id> <project> <main-home> <secondmate-home> <secondmate-project>
  local capability=$1 id=$2 project=$3 main_home=$4 secondmate_home=$5 secondmate_project=$6
  local canonical_main canonical_second canonical_project main_project main_git secondmate_git main_identity secondmate_identity anchor
  fm_local_route_record_load "$capability" || return 1
  canonical_main=$(fm_local_route_canonical_dir "$main_home") || {
    FM_LOCAL_ROUTE_ERROR="guarded main home path is unsafe or symlinked"
    return 1
  }
  canonical_second=$(fm_local_route_canonical_dir "$secondmate_home") || {
    FM_LOCAL_ROUTE_ERROR="guarded secondmate home path is unsafe or symlinked"
    return 1
  }
  canonical_project=$(fm_local_route_canonical_dir "$secondmate_project") || {
    FM_LOCAL_ROUTE_ERROR="guarded secondmate project path is unsafe or symlinked"
    return 1
  }
  [ "$FM_LOCAL_ROUTE_SECONDMATE_ID" = "$id" ] && [ "$FM_LOCAL_ROUTE_PROJECT" = "$project" ] \
    && [ "$FM_LOCAL_ROUTE_MAIN_HOME" = "$canonical_main" ] \
    && [ "$FM_LOCAL_ROUTE_SECONDMATE_HOME" = "$canonical_second" ] \
    && [ "$FM_LOCAL_ROUTE_SECONDMATE_PROJECT" = "$canonical_project" ] || {
      FM_LOCAL_ROUTE_ERROR="local-project capability identity drifted"
      return 1
    }
  main_project=$(fm_local_route_canonical_dir "$FM_LOCAL_ROUTE_MAIN_PROJECT") || {
    FM_LOCAL_ROUTE_ERROR="guarded main project path is unsafe or symlinked"
    return 1
  }
  main_git=$(fm_local_route_git_common_dir "$main_project") || {
    FM_LOCAL_ROUTE_ERROR="guarded main repository identity drifted"
    return 1
  }
  secondmate_git=$(fm_local_route_git_common_dir "$canonical_project") || {
    FM_LOCAL_ROUTE_ERROR="guarded secondmate repository identity drifted"
    return 1
  }
  [ "$main_git" = "$main_project/.git" ] && [ "$secondmate_git" = "$canonical_project/.git" ] || {
    FM_LOCAL_ROUTE_ERROR="local-project repository is not an isolated ordinary clone"
    return 1
  }
  main_identity=$(fm_local_route_path_identity "$main_git") || {
    FM_LOCAL_ROUTE_ERROR="guarded main repository identity drifted"
    return 1
  }
  secondmate_identity=$(fm_local_route_path_identity "$secondmate_git") || {
    FM_LOCAL_ROUTE_ERROR="guarded secondmate repository identity drifted"
    return 1
  }
  [ "$main_git" = "$FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR" ] \
    && [ "$main_identity" = "$FM_LOCAL_ROUTE_MAIN_GIT_IDENTITY" ] \
    && [ "$secondmate_git" = "$FM_LOCAL_ROUTE_SECONDMATE_GIT_COMMON_DIR" ] \
    && [ "$secondmate_identity" = "$FM_LOCAL_ROUTE_SECONDMATE_GIT_IDENTITY" ] || {
      FM_LOCAL_ROUTE_ERROR="local-project repository identity drifted"
      return 1
    }
  anchor=$FM_LOCAL_ROUTE_ANCHOR_OID
  git -C "$main_project" cat-file -e "$anchor^{commit}" 2>/dev/null \
    && git -C "$canonical_project" cat-file -e "$anchor^{commit}" 2>/dev/null || {
      FM_LOCAL_ROUTE_ERROR="local-project repository ancestry drifted"
      return 1
    }
  fm_local_route_all_remotes_local "$main_project" "main local-only project" || return 1
  fm_local_route_all_remotes_local "$canonical_project" "secondmate local-only project" || return 1
  fm_local_route_exact_origin "$canonical_project" "$main_project" || return 1
}

fm_local_return_receipt_load() { # <receipt-file>; route identity globals are shared with capability loads
  local file=$1 line key value
  local schema='' secondmate_id='' project='' task_id='' branch='' main_home='' main_project='' main_git=''
  local secondmate_home='' secondmate_project='' secondmate_git='' base_oid='' head_oid=''
  local schema_n=0 secondmate_id_n=0 project_n=0 task_id_n=0 branch_n=0 main_home_n=0 main_project_n=0 main_git_n=0
  local secondmate_home_n=0 secondmate_project_n=0 secondmate_git_n=0 base_oid_n=0 head_oid_n=0
  FM_LOCAL_ROUTE_ERROR=
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    FM_LOCAL_ROUTE_ERROR="local branch-return receipt is unavailable or unsafe"
    return 1
  fi
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || {
    FM_LOCAL_ROUTE_ERROR="local branch-return receipt is unavailable or unsafe"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || { FM_LOCAL_ROUTE_ERROR="local branch-return receipt is malformed"; return 1; }
    case "$key" in
      schema) schema_n=$((schema_n + 1)); schema=$value ;;
      secondmate_id) secondmate_id_n=$((secondmate_id_n + 1)); secondmate_id=$value ;;
      project) project_n=$((project_n + 1)); project=$value ;;
      task_id) task_id_n=$((task_id_n + 1)); task_id=$value ;;
      branch) branch_n=$((branch_n + 1)); branch=$value ;;
      main_home) main_home_n=$((main_home_n + 1)); main_home=$value ;;
      main_project) main_project_n=$((main_project_n + 1)); main_project=$value ;;
      main_git_common_dir) main_git_n=$((main_git_n + 1)); main_git=$value ;;
      secondmate_home) secondmate_home_n=$((secondmate_home_n + 1)); secondmate_home=$value ;;
      secondmate_project) secondmate_project_n=$((secondmate_project_n + 1)); secondmate_project=$value ;;
      secondmate_git_common_dir) secondmate_git_n=$((secondmate_git_n + 1)); secondmate_git=$value ;;
      base_oid) base_oid_n=$((base_oid_n + 1)); base_oid=$value ;;
      head_oid) head_oid_n=$((head_oid_n + 1)); head_oid=$value ;;
      *) FM_LOCAL_ROUTE_ERROR="local branch-return receipt is malformed"; return 1 ;;
    esac
  done < "$file"
  [ "$schema_n" -eq 1 ] && [ "$secondmate_id_n" -eq 1 ] && [ "$project_n" -eq 1 ] \
    && [ "$task_id_n" -eq 1 ] && [ "$branch_n" -eq 1 ] && [ "$main_home_n" -eq 1 ] \
    && [ "$main_project_n" -eq 1 ] && [ "$main_git_n" -eq 1 ] && [ "$secondmate_home_n" -eq 1 ] \
    && [ "$secondmate_project_n" -eq 1 ] && [ "$secondmate_git_n" -eq 1 ] \
    && [ "$base_oid_n" -eq 1 ] && [ "$head_oid_n" -eq 1 ] || {
      FM_LOCAL_ROUTE_ERROR="local branch-return receipt is malformed"
      return 1
    }
  [ "$schema" = fm-local-branch-return.v1 ] \
    && fm_local_route_safe_id "$secondmate_id" && fm_local_route_safe_id "$project" \
    && fm_local_route_safe_id "$task_id" && [ "$branch" = "fm/$task_id" ] \
    && [[ "$base_oid" =~ ^[0-9a-f]{40,64}$ ]] && [[ "$head_oid" =~ ^[0-9a-f]{40,64}$ ]] || {
      FM_LOCAL_ROUTE_ERROR="local branch-return receipt is malformed"
      return 1
    }
  FM_LOCAL_ROUTE_SECONDMATE_ID=$secondmate_id
  FM_LOCAL_ROUTE_PROJECT=$project
  FM_LOCAL_ROUTE_MAIN_HOME=$main_home
  FM_LOCAL_ROUTE_MAIN_PROJECT=$main_project
  FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR=$main_git
  FM_LOCAL_ROUTE_SECONDMATE_HOME=$secondmate_home
  FM_LOCAL_ROUTE_SECONDMATE_PROJECT=$secondmate_project
  FM_LOCAL_ROUTE_SECONDMATE_GIT_COMMON_DIR=$secondmate_git
  FM_LOCAL_RETURN_TASK_ID=$task_id
  FM_LOCAL_RETURN_BRANCH=$branch
  FM_LOCAL_RETURN_BASE_OID=$base_oid
  FM_LOCAL_RETURN_HEAD_OID=$head_oid
}

fm_local_return_receipt_write() { # <file> plus route identity and task/base/head args
  local file=$1 id=$2 project=$3 task=$4 main_home=$5 main_project=$6 main_git=$7
  local secondmate_home=$8 secondmate_project=$9 secondmate_git=${10} base_oid=${11} head_oid=${12} tmp
  mkdir -p "$(dirname "$file")" || return 1
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$(dirname "$file")/.return.XXXXXX") || return 1
  {
    printf 'schema=fm-local-branch-return.v1\n'
    printf 'secondmate_id=%s\n' "$id"
    printf 'project=%s\n' "$project"
    printf 'task_id=%s\n' "$task"
    printf 'branch=fm/%s\n' "$task"
    printf 'main_home=%s\n' "$main_home"
    printf 'main_project=%s\n' "$main_project"
    printf 'main_git_common_dir=%s\n' "$main_git"
    printf 'secondmate_home=%s\n' "$secondmate_home"
    printf 'secondmate_project=%s\n' "$secondmate_project"
    printf 'secondmate_git_common_dir=%s\n' "$secondmate_git"
    printf 'base_oid=%s\n' "$base_oid"
    printf 'head_oid=%s\n' "$head_oid"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

fm_local_route_value_exact() { # <ordinary record> <key>
  local file=$1 key=$2 count
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^${key}=" "$file" | cut -d= -f2-
}
