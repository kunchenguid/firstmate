# shellcheck shell=bash
# Shared PR/MR provider seam for firstmate's ship lifecycle.
# Usage: . bin/fm-scm-lib.sh
#
# Providers are selected from a full PR/MR URL first, then from the worktree's
# origin remote for teardown's no-pr= branch-discovery fallback.
# GitHub operations keep using gh/gh-axi.
# Codebase operations use bytedcli only; lookup failures print an actionable
# bytedcli/auth hint and return non-zero so callers fail closed.

fm_scm_github_repo_path_safe() {
  local path=$1 owner repo
  case "$path" in
    */*/*|/*|*/|'') return 1 ;;
  esac
  owner=${path%%/*}
  repo=${path#*/}
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 1
  [[ "$owner" != *- ]] || return 1
  [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]]
}

fm_scm_codebase_repo_path_safe() {
  local path=$1
  case "$path" in
    ''|/*|*/|*'//'*) return 1 ;;
  esac
  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]]
}

fm_scm_strip_git_suffix() {
  local path=$1
  path=${path%.git}
  printf '%s\n' "$path"
}

fm_scm_number_safe() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Echo provider<TAB>repo-path<TAB>number for supported full URLs.
fm_scm_parse_pr_url() {
  local url=$1 rest repo number host
  rest=${url%/}
  if [[ "$rest" == https://github.com/*/pull/* ]]; then
    rest=${rest#https://github.com/}
    number=${rest##*/pull/}
    repo=${rest%/pull/*}
    if fm_scm_number_safe "$number" && fm_scm_github_repo_path_safe "$repo"; then
      printf 'github\t%s\t%s\n' "$repo" "$number"
      return 0
    fi
  fi

  for host in code.byted.org code-tx.byted.org; do
    if [[ "$rest" == https://"$host"/*/merge_requests/* ]]; then
      rest=${rest#https://"$host"/}
      number=${rest##*/merge_requests/}
      repo=${rest%/merge_requests/*}
      if fm_scm_number_safe "$number" && fm_scm_codebase_repo_path_safe "$repo"; then
        printf 'codebase\t%s\t%s\n' "$repo" "$number"
        return 0
      fi
    fi
  done

  case "$url" in
    https://github.com/*)
      echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
      ;;
    https://code.byted.org/*|https://code-tx.byted.org/*)
      echo "error: Codebase MR URL must match https://code.byted.org/<repo-path>/merge_requests/<number> (got: $url)" >&2
      ;;
    *)
      echo "error: PR/MR URL must match https://github.com/<owner>/<repo>/pull/<number> or https://code.byted.org/<repo-path>/merge_requests/<number> (got: $url)" >&2
      ;;
  esac
  return 1
}

fm_scm_remote_path_after_host() {
  local remote=$1 host=$2 rest prefix
  for prefix in "http://$host/" "https://$host/" "ssh://$host/"; do
    case "$remote" in
      "$prefix"*)
        printf '%s\n' "${remote#"$prefix"}"
        return 0
        ;;
    esac
  done
  for prefix in "http://" "https://" "ssh://"; do
    case "$remote" in
      "$prefix"*"@$host/"*)
        rest=${remote#"$prefix"}
        rest=${rest#*@"$host"/}
        printf '%s\n' "$rest"
        return 0
        ;;
    esac
  done
  case "$remote" in
    *"@$host":*)
      rest=${remote#*@"$host":}
      printf '%s\n' "$rest"
      return 0
      ;;
  esac
  return 1
}

# Echo provider<TAB>repo-path for supported git remote URLs.
fm_scm_parse_remote_url() {
  local remote=$1 path host
  if path=$(fm_scm_remote_path_after_host "$remote" github.com); then
    path=$(fm_scm_strip_git_suffix "$path")
    if fm_scm_github_repo_path_safe "$path"; then
      printf 'github\t%s\n' "$path"
      return 0
    fi
  fi

  for host in code.byted.org code-tx.byted.org; do
    if path=$(fm_scm_remote_path_after_host "$remote" "$host"); then
      path=$(fm_scm_strip_git_suffix "$path")
      if fm_scm_codebase_repo_path_safe "$path"; then
        printf 'codebase\t%s\n' "$path"
        return 0
      fi
    fi
  done

  return 1
}

fm_scm_remote_info() {
  local worktree=$1 remote
  [ -n "$worktree" ] || return 1
  remote=$(git -C "$worktree" remote get-url origin 2>/dev/null) || return 1
  fm_scm_parse_remote_url "$remote"
}

fm_scm_target_number() {
  local worktree=$1 target=$2 parsed number
  case "$target" in
    [0-9]*)
      number=${target%%[!0-9]*}
      [ -n "$number" ] || return 1
      printf '%s\n' "$number"
      return 0
      ;;
  esac
  parsed=$(fm_scm_parse_pr_url "$target") || return 1
  IFS=$'\t' read -r _ _ number <<EOF
$parsed
EOF
  [ -n "$number" ] || return 1
  printf '%s\n' "$number"
}

fm_scm_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq not found; install jq so firstmate can parse Codebase JSON from bytedcli." >&2
    return 1
  }
}

fm_scm_require_bytedcli() {
  command -v bytedcli >/dev/null 2>&1 || {
    echo "error: bytedcli not found; install it with: NPM_CONFIG_REGISTRY=http://bnpm.byted.org npm install -g @bytedance-dev/bytedcli@latest" >&2
    return 1
  }
}

fm_scm_codebase_lookup_error() {
  local action=$1 repo=$2 number=$3 detail=${4:-}
  echo "error: bytedcli Codebase $action failed for $repo!$number." >&2
  echo "Check authentication with 'bytedcli --json auth status', or configure Codebase auth with 'bytedcli codebase auth config-add-pat <pat>'." >&2
  [ -z "$detail" ] || printf '%s\n' "$detail" | sed 's/^/bytedcli: /' >&2
}

fm_scm_codebase_json_status_ok() {
  jq -e '.status == "success"' >/dev/null 2>&1
}

fm_scm_codebase_error_detail() {
  jq -r '(.error.hint // .error.message // .error // empty) | tostring' 2>/dev/null
}

fm_scm_codebase_mr_json() {
  local number=$1 repo=$2 err_file out err detail
  fm_scm_require_jq || return 1
  fm_scm_require_bytedcli || return 1
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-codebase-mr.XXXXXX") || return 1
  if ! out=$(bytedcli --json codebase mr get "$number" -R "$repo" 2>"$err_file"); then
    err=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    fm_scm_codebase_lookup_error "MR lookup" "$repo" "$number" "$err"
    return 1
  fi
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  if ! printf '%s\n' "$out" | fm_scm_codebase_json_status_ok; then
    detail=$(printf '%s\n' "$out" | fm_scm_codebase_error_detail)
    [ -n "$detail" ] || detail=$err
    fm_scm_codebase_lookup_error "MR lookup" "$repo" "$number" "$detail"
    return 1
  fi
  printf '%s\n' "$out"
}

fm_scm_codebase_mr_list_json() {
  local repo=$1 branch=$2 err_file out err detail
  fm_scm_require_jq || return 1
  fm_scm_require_bytedcli || return 1
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-codebase-list.XXXXXX") || return 1
  if ! out=$(bytedcli --json codebase mr list -R "$repo" --state merged --head "$branch" -L 1 2>"$err_file"); then
    err=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    fm_scm_codebase_lookup_error "MR branch lookup" "$repo" "$branch" "$err"
    return 1
  fi
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  if ! printf '%s\n' "$out" | fm_scm_codebase_json_status_ok; then
    detail=$(printf '%s\n' "$out" | fm_scm_codebase_error_detail)
    [ -n "$detail" ] || detail=$err
    fm_scm_codebase_lookup_error "MR branch lookup" "$repo" "$branch" "$detail"
    return 1
  fi
  printf '%s\n' "$out"
}

# Echo provider<TAB>state<TAB>head-commit<TAB>source-ref.
fm_scm_pr_info() {
  local worktree=$1 target=$2 parsed provider repo number view state head json
  if parsed=$(fm_scm_parse_pr_url "$target" 2>/dev/null); then
    IFS=$'\t' read -r provider repo number <<EOF
$parsed
EOF
  else
    case "$target" in
      [0-9]*) ;;
      *) return 1 ;;
    esac
    parsed=$(fm_scm_remote_info "$worktree") || return 1
    IFS=$'\t' read -r provider repo <<EOF
$parsed
EOF
    number=${target%%[!0-9]*}
  fi

  case "$provider" in
    github)
      if [ -n "$worktree" ] && [ -d "$worktree" ]; then
        view=$(cd "$worktree" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
      else
        view=$(gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
      fi
      state=${view%%$'\t'*}
      head=${view#*$'\t'}
      [ "$state" != "$view" ] || return 1
      printf 'github\t%s\t%s\t\n' "$state" "$head"
      ;;
    codebase)
      json=$(fm_scm_codebase_mr_json "$number" "$repo") || return 1
      printf '%s\n' "$json" | jq -r '
        .data.merge_request as $mr
        | (.data.version // (($mr.Versions // []) | last) // {}) as $version
        | [
            "codebase",
            ($mr.Status // $mr.status // ""),
            ($version.SourceCommitId // $mr.SourceCommitId // ""),
            ($version.SourceRef // $mr.SourceRef // "")
          ]
        | @tsv
      '
      ;;
    *) return 1 ;;
  esac
}

fm_scm_pr_state() {
  local worktree=$1 target=$2 info provider state
  info=$(fm_scm_pr_info "$worktree" "$target") || return 1
  IFS=$'\t' read -r provider state _ _ <<EOF
$info
EOF
  [ -n "$provider" ] || return 1
  printf '%s\n' "$state"
}

fm_scm_pr_head() {
  local worktree=$1 target=$2 info provider state head
  info=$(fm_scm_pr_info "$worktree" "$target") || return 1
  IFS=$'\t' read -r provider state head _ <<EOF
$info
EOF
  [ -n "$provider" ] && [ -n "$state" ] && [ -n "$head" ] || return 1
  printf '%s\n' "$head"
}

fm_scm_target_from_branch() {
  local worktree=$1 branch=$2 parsed provider repo out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  parsed=$(fm_scm_remote_info "$worktree") || return 1
  IFS=$'\t' read -r provider repo <<EOF
$parsed
EOF
  case "$provider" in
    github)
      out=$(cd "$worktree" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
      n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
      [ -n "$n" ] || return 1
      printf '%s\n' "$n"
      ;;
    codebase)
      out=$(fm_scm_codebase_mr_list_json "$repo" "$branch") || return 1
      n=$(printf '%s\n' "$out" | jq -r '(.data.merge_requests // [])[0].Number // empty')
      [ -n "$n" ] || return 1
      printf '%s\n' "$n"
      ;;
    *) return 1 ;;
  esac
}

fm_scm_fetch_pr_head() {
  local worktree=$1 provider=$2 target=$3 commit=$4 source_ref=${5:-} n
  git -C "$worktree" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  git -C "$worktree" remote get-url origin >/dev/null 2>&1 || return 1
  case "$provider" in
    github)
      n=$(fm_scm_target_number "$worktree" "$target") || return 1
      git -C "$worktree" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
      ;;
    codebase)
      [ -n "$source_ref" ] || return 1
      git -C "$worktree" fetch --quiet origin "$source_ref" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  git -C "$worktree" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_scm_reject_url_override_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*|--repo-id|--repo-id=*|--mr-id|--mr-id=*)
        echo "error: extra merge args must not override the repository or MR parsed from the PR/MR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

fm_scm_github_caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

fm_scm_codebase_caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*|--merge-method|--merge-method=*|--squash-commits|--squash-commits=*) return 0 ;;
    esac
  done
  return 1
}

fm_scm_github_merge() {
  local number=$1 repo=$2
  shift 2
  local merge_args=()
  if ! fm_scm_github_caller_has_merge_method "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$number" --repo "$repo" ${merge_args[@]+"${merge_args[@]}"} "$@"
}

fm_scm_codebase_append_method() {
  local method=$1
  case "$method" in
    merge) FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method merge_commit --squash-commits false) ;;
    squash) FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method merge_commit --squash-commits true) ;;
    rebase) FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method rebase_merge --squash-commits false) ;;
    merge_commit|rebase_merge) FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method "$method") ;;
    *)
      echo "error: unsupported Codebase merge method '$method'; use merge, squash, rebase, merge_commit, or rebase_merge" >&2
      return 1
      ;;
  esac
}

fm_scm_codebase_merge() {
  local number=$1 repo=$2 arg method
  shift 2
  fm_scm_require_bytedcli || return 1

  FM_SCM_CODEBASE_MERGE_ARGS=()
  if ! fm_scm_codebase_caller_has_merge_method "$@"; then
    FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method merge_commit --squash-commits true)
  fi

  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --squash)
        FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method merge_commit --squash-commits true)
        shift
        ;;
      --merge)
        FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method merge_commit --squash-commits false)
        shift
        ;;
      --rebase)
        FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method rebase_merge --squash-commits false)
        shift
        ;;
      --method=*)
        method=${arg#--method=}
        fm_scm_codebase_append_method "$method" || return 1
        shift
        ;;
      --method)
        [ "$#" -ge 2 ] || { echo "error: --method requires a value" >&2; return 1; }
        method=$2
        fm_scm_codebase_append_method "$method" || return 1
        shift 2
        ;;
      --delete-branch)
        FM_SCM_CODEBASE_MERGE_ARGS+=(--remove-source-branch true)
        shift
        ;;
      --merge-method|--squash-commits|--remove-source-branch|--merge-commit-message|--squash-commit-message)
        [ "$#" -ge 2 ] || { echo "error: $arg requires a value" >&2; return 1; }
        FM_SCM_CODEBASE_MERGE_ARGS+=("$arg" "$2")
        shift 2
        ;;
      --merge-method=*|--squash-commits=*|--remove-source-branch=*|--merge-commit-message=*|--squash-commit-message=*)
        FM_SCM_CODEBASE_MERGE_ARGS+=("$arg")
        shift
        ;;
      *)
        FM_SCM_CODEBASE_MERGE_ARGS+=("$arg")
        shift
        ;;
    esac
  done

  bytedcli codebase mr merge "$number" -R "$repo" "${FM_SCM_CODEBASE_MERGE_ARGS[@]}"
}

fm_scm_merge_url() {
  local url=$1 parsed provider repo number
  shift
  parsed=$(fm_scm_parse_pr_url "$url") || return 1
  IFS=$'\t' read -r provider repo number <<EOF
$parsed
EOF
  case "$provider" in
    github) fm_scm_github_merge "$number" "$repo" "$@" ;;
    codebase) fm_scm_codebase_merge "$number" "$repo" "$@" ;;
    *) return 1 ;;
  esac
}
