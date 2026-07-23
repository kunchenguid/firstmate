# shellcheck shell=bash
# Shared PR/MR provider seam for firstmate's ship lifecycle.
# Usage: . bin/fm-scm-lib.sh
#
# Providers are selected from a full PR/MR URL first, then from the worktree's
# origin remote for teardown's no-pr= branch-discovery fallback.
# GitHub operations keep using gh/gh-axi.
# Codebase operations use bytedcli only; lookup failures print an actionable
# bytedcli/auth hint and return non-zero so callers fail closed.
#
# fm_scm_pr_info's record is unit-separated rather than tab-separated: tab is IFS
# whitespace, so `IFS=$'\t' read` collapses runs of tabs and shifts every field
# after an empty one left.

FM_SCM_FS=$'\037'

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
  local path=$1 segment rest segments=0
  case "$path" in
    ''|/*|*/|*'//'*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  rest=$path
  while [ -n "$rest" ]; do
    segment=${rest%%/*}
    if [ "$segment" = "$rest" ]; then
      rest=
    else
      rest=${rest#*/}
    fi
    [[ "$segment" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    segments=$((segments + 1))
  done
  [ "$segments" -ge 2 ]
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

# A provider-supplied ref is only ever fetched when it is a fully-qualified
# refs/ name, so git can never read it as an option such as --upload-pack=.
fm_scm_ref_safe() {
  local ref=$1
  case "$ref" in
    refs/*) ;;
    *) return 1 ;;
  esac
  case "$ref" in
    *..*|*//*|*/) return 1 ;;
  esac
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]
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
  local remote=$1 host=$2 rest port
  case "$remote" in
    *://*)
      rest=${remote#*://}
      case "${rest%%/*}" in
        *@*) rest=${rest#*@} ;;
      esac
      case "$rest" in
        "$host"/*) rest=${rest#"$host"/} ;;
        "$host":*/*)
          rest=${rest#"$host":}
          port=${rest%%/*}
          case "$port" in
            ''|*[!0-9]*) return 1 ;;
          esac
          rest=${rest#*/}
          ;;
        *) return 1 ;;
      esac
      ;;
    *"@$host":*)
      rest=${remote#*@"$host":}
      ;;
    *) return 1 ;;
  esac
  while [ "${rest%/}" != "$rest" ]; do
    rest=${rest%/}
  done
  [ -n "$rest" ] || return 1
  printf '%s\n' "$rest"
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

# Run one bytedcli Codebase JSON lookup and echo its response on success.
# Args: <action-label> <repo> <identifier> <bytedcli args...>
fm_scm_codebase_json() {
  local action=$1 repo=$2 identifier=$3
  shift 3
  local err_file out err detail
  fm_scm_require_jq || return 1
  fm_scm_require_bytedcli || return 1
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-codebase.XXXXXX") || return 1
  if ! out=$(bytedcli "$@" 2>"$err_file"); then
    err=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    fm_scm_codebase_lookup_error "$action" "$repo" "$identifier" "$err"
    return 1
  fi
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  if ! printf '%s\n' "$out" | fm_scm_codebase_json_status_ok; then
    detail=$(printf '%s\n' "$out" | fm_scm_codebase_error_detail)
    [ -n "$detail" ] || detail=$err
    fm_scm_codebase_lookup_error "$action" "$repo" "$identifier" "$detail"
    return 1
  fi
  printf '%s\n' "$out"
}

fm_scm_codebase_mr_json() {
  local number=$1 repo=$2
  fm_scm_codebase_json "MR lookup" "$repo" "$number" \
    --json codebase mr get "$number" -R "$repo"
}

fm_scm_codebase_mr_list_json() {
  local repo=$1 branch=$2
  fm_scm_codebase_json "MR branch lookup" "$repo" "$branch" \
    --json codebase mr list -R "$repo" --state merged --head "$branch" -L 1
}

fm_scm_codebase_commit_json() {
  local sha=$1 repo=$2
  fm_scm_codebase_json "commit lookup" "$repo" "$sha" \
    --json codebase commit get -r "$sha" -R "$repo"
}

# Echo the MR's internal Id, unit-separated from the head commit of its latest
# version. `bytedcli codebase mr merge` takes neither the MR URL nor the
# user-visible Number: --mr-id is its only selector and it wants this internal
# Id, so every Codebase merge has to resolve one first.
fm_scm_codebase_mr_merge_facts() {
  local number=$1 repo=$2 json
  json=$(fm_scm_codebase_mr_json "$number" "$repo") || return 1
  printf '%s\n' "$json" | jq -r '
    .data.merge_request as $mr
    | (.data.version // (($mr.Versions // []) | last) // {}) as $version
    | [
        ((($mr.Id // $mr.id) // "") | tostring),
        ($version.SourceCommitId // $mr.SourceCommitId // "")
      ]
    | join("\u001f")
  '
}

# Echo how many parents a commit has, so a merge commit (2+) is distinguishable
# from an ordinary one. Fails when the commit cannot be read, which callers must
# treat as "unknown", never as "not a merge commit".
fm_scm_codebase_commit_parents() {
  local sha=$1 repo=$2 json parents
  [ -n "$sha" ] || return 1
  json=$(fm_scm_codebase_commit_json "$sha" "$repo") || return 1
  parents=$(printf '%s\n' "$json" | jq -r '(.data.commit.Parents // []) | length') || return 1
  case "$parents" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$parents"
}

# Echo provider<US>state<US>head-commit<US>source-ref, unit-separated so an empty
# field (a Codebase MR version with no SourceCommitId) cannot shift the rest left.
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
      printf '%s\n' "github${FM_SCM_FS}${state}${FM_SCM_FS}${head}${FM_SCM_FS}"
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
        | join("\u001f")
      '
      ;;
    *) return 1 ;;
  esac
}

fm_scm_pr_state() {
  local worktree=$1 target=$2 info provider state
  info=$(fm_scm_pr_info "$worktree" "$target") || return 1
  IFS=$FM_SCM_FS read -r provider state _ _ <<EOF
$info
EOF
  [ -n "$provider" ] && [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}

fm_scm_pr_head() {
  local worktree=$1 target=$2 info provider state head
  info=$(fm_scm_pr_info "$worktree" "$target") || return 1
  IFS=$FM_SCM_FS read -r provider state head _ <<EOF
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
      git -C "$worktree" fetch --quiet origin -- "refs/pull/$n/head" >/dev/null 2>&1 || return 1
      ;;
    codebase)
      fm_scm_ref_safe "$source_ref" || return 1
      git -C "$worktree" fetch --quiet origin -- "$source_ref" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  git -C "$worktree" cat-file -e "$commit^{commit}" 2>/dev/null
}

# Echo the current commit the PR/MR head points at, fetching it into the worktree
# first. The provider's current head wins; a reachable recorded head is only an
# offline fallback when the provider cannot resolve or fetch the current one.
fm_scm_resolve_pr_head() {
  local worktree=$1 target=$2 recorded_head=${3:-} parsed provider info head source_ref number
  [ -n "$target" ] || return 1
  if parsed=$(fm_scm_parse_pr_url "$target" 2>/dev/null); then
    IFS=$'\t' read -r provider _ _ <<EOF
$parsed
EOF
  else
    case "$target" in
      [0-9]*) ;;
      *) return 1 ;;
    esac
    parsed=$(fm_scm_remote_info "$worktree") || return 1
    IFS=$'\t' read -r provider _ <<EOF
$parsed
EOF
  fi

  case "$provider" in
    github)
      if number=$(fm_scm_target_number "$worktree" "$target") \
        && git -C "$worktree" remote get-url origin >/dev/null 2>&1 \
        && git -C "$worktree" fetch --quiet origin \
          "+refs/pull/$number/head:refs/fm-review/pull/$number/head" >/dev/null 2>&1 \
        && head=$(git -C "$worktree" rev-parse --verify "refs/fm-review/pull/$number/head^{commit}" 2>/dev/null); then
        :
      else
        head=
      fi
      ;;
    codebase)
      if info=$(fm_scm_pr_info "$worktree" "$target" 2>/dev/null); then
        IFS=$FM_SCM_FS read -r _ _ head source_ref <<EOF
$info
EOF
        [ -n "$head" ] && fm_scm_fetch_pr_head "$worktree" codebase "$target" "$head" "$source_ref" || head=
      fi
      ;;
    *) return 1 ;;
  esac
  if [ -z "$head" ] && [ -n "$recorded_head" ] \
    && git -C "$worktree" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    head=$recorded_head
  fi
  [ -n "$head" ] || return 1
  printf '%s\n' "$head"
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

# Does the caller already choose a merge method? --squash-commits is a modifier,
# not a method, so it never counts here.
fm_scm_caller_has_merge_method() {
  local provider=$1 arg
  shift
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
    case "$provider:$arg" in
      codebase:--merge-method|codebase:--merge-method=*) return 0 ;;
    esac
  done
  return 1
}

fm_scm_codebase_caller_has_squash_commits() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash-commits|--squash-commits=*) return 0 ;;
    esac
  done
  return 1
}

fm_scm_github_merge() {
  local number=$1 repo=$2
  shift 2
  local merge_args=()
  if ! fm_scm_caller_has_merge_method github "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$number" --repo "$repo" ${merge_args[@]+"${merge_args[@]}"} "$@"
}

# Echo the merge args' resolved --squash-commits value (last one wins), empty
# when none was set. Read from the final arg list, so a caller shim such as
# --squash and a raw --squash-commits=true both land here.
fm_scm_codebase_resolved_squash() {
  local arg val='' want_value=0
  for arg in "$@"; do
    if [ "$want_value" = 1 ]; then
      val=$arg
      want_value=0
      continue
    fi
    case "$arg" in
      --squash-commits) want_value=1 ;;
      --squash-commits=*) val=${arg#--squash-commits=} ;;
    esac
  done
  printf '%s\n' "$val" | tr '[:upper:]' '[:lower:]'
}

# Squashing an MR whose head is itself a merge commit flattens that merge and
# drops its second parent, destroying the merge base with the branch it merged.
# The next merge from that same upstream then replays every already-merged change
# as a conflict. Refuse instead, and refuse just as hard when the head cannot be
# read: "unknown" must never be treated as "not a merge commit".
fm_scm_codebase_reject_squash_of_merge_head() {
  local number=$1 repo=$2 head=$3 parents
  if [ -z "$head" ]; then
    echo "error: refusing to squash $repo!$number: firstmate could not resolve its head commit, so it cannot rule out a merge commit." >&2
    return 1
  fi
  if ! parents=$(fm_scm_codebase_commit_parents "$head" "$repo"); then
    echo "error: refusing to squash $repo!$number: firstmate could not read head commit $head, so it cannot rule out a merge commit." >&2
    return 1
  fi
  [ "$parents" -ge 2 ] || return 0
  echo "error: refusing to squash $repo!$number: its head commit $head is a merge commit ($parents parents)." >&2
  echo "Squashing it would flatten that merge and drop the second parent, destroying the merge base; the next merge from the same upstream would then replay every already-merged change as a conflict." >&2
  echo "Merge it with --merge instead, which keeps the merge commit." >&2
  return 1
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
  local number=$1 repo=$2 arg method facts mr_id head
  shift 2
  fm_scm_require_bytedcli || return 1

  local FM_SCM_CODEBASE_MERGE_ARGS=()
  # Codebase's default is a real merge commit, never a squash: Codebase MRs are
  # routinely upstream-merge MRs whose head is a merge commit, and squashing one
  # of those destroys the merge base (see the reject helper above). GitHub's
  # --squash default is unaffected.
  if ! fm_scm_caller_has_merge_method codebase "$@"; then
    FM_SCM_CODEBASE_MERGE_ARGS+=(--merge-method merge_commit)
    if ! fm_scm_codebase_caller_has_squash_commits "$@"; then
      FM_SCM_CODEBASE_MERGE_ARGS+=(--squash-commits false)
    fi
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

  facts=$(fm_scm_codebase_mr_merge_facts "$number" "$repo") || return 1
  IFS=$FM_SCM_FS read -r mr_id head <<EOF
$facts
EOF
  if [ -z "$mr_id" ]; then
    echo "error: could not resolve an internal MR id for $repo!$number; bytedcli codebase mr merge accepts no other selector." >&2
    return 1
  fi

  case "$(fm_scm_codebase_resolved_squash ${FM_SCM_CODEBASE_MERGE_ARGS[@]+"${FM_SCM_CODEBASE_MERGE_ARGS[@]}"})" in
    true|1|yes)
      fm_scm_codebase_reject_squash_of_merge_head "$number" "$repo" "$head" || return 1
      ;;
  esac

  bytedcli codebase mr merge --mr-id "$mr_id" -R "$repo" ${FM_SCM_CODEBASE_MERGE_ARGS[@]+"${FM_SCM_CODEBASE_MERGE_ARGS[@]}"}
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

# --- legacy poll upgrade -----------------------------------------------------
# Before bin/fm-poll-lib.sh existed, bin/fm-pr-check.sh inlined the poll's whole
# judgement into the state/<id>.check.sh it generated. Those files are never
# rewritten, so a poll armed then is frozen at that day's logic forever: one
# armed on 2026-07-17 was still asking only "merged?" weeks later, blind to every
# signal added since, while a poll armed after the change saw them. The one thing
# such a file does reach for on every cycle is THIS library, which it loads from
# disk. So this is where an old poll is upgraded: when a pre-library poll sources
# us, we run the current poll for its task and exit in its place, and it never
# reaches its own frozen logic.
#
# The takeover is deliberately narrow. It fires only for a caller that set
# fm_scm_marker to a .check.error path (nothing but a generated poll ever did),
# only when the current library and that task's recorded PR are both readable,
# and never re-entrantly. Anything else falls through and the old file runs
# exactly as before, which is also the right answer when the upgrade cannot be
# completed safely.
fm_scm_legacy_poll_id() {  # echo the task id when a pre-library poll sourced us
  local marker=${fm_scm_marker:-} base
  [ -n "$marker" ] || return 1
  [ -n "${fm_scm_fails:-}" ] || return 1
  case "$marker" in
    */*.check.error) ;;
    *) return 1 ;;
  esac
  base=${marker##*/}
  printf '%s\n' "${base%.check.error}"
}

if [ -z "${fm_poll_shim_active:-}" ] && fm_scm_legacy_poll_id >/dev/null 2>&1; then
  fm_scm_legacy_id=$(fm_scm_legacy_poll_id)
  fm_scm_legacy_state=${fm_scm_marker%/*}
  # The frozen file bakes its PR URL into strings rather than a variable, so the
  # URL comes from the task's own record, which is where the current poll reads
  # every other parameter from too. No record, no upgrade.
  if [ -n "$(grep '^pr=' "$fm_scm_legacy_state/$fm_scm_legacy_id.meta" 2>/dev/null || true)" ]; then
    fm_scm_legacy_poll_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/fm-poll-lib.sh"
    fm_poll_shim_active=1
    # shellcheck source=bin/fm-poll-lib.sh
    if [ -r "$fm_scm_legacy_poll_lib" ] && . "$fm_scm_legacy_poll_lib"; then
      fm_poll_run "$fm_scm_legacy_state" "$fm_scm_legacy_id"
      exit 0
    fi
    unset fm_poll_shim_active fm_scm_legacy_poll_lib
  fi
  unset fm_scm_legacy_id fm_scm_legacy_state
fi
