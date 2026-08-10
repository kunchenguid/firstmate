#!/usr/bin/env bash
# A `gh` shim that routes pull-request mutations through fm-gh.sh and gives the
# no-mistakes CI read one exact-head, least-privilege workflow-runs fallback.
#
# Install it as a SYMLINK named `gh` in a directory that precedes the real gh on the
# PATH of the process you need to intercept; bin/fm-gh-shim-install.sh owns
# installation, removal, and the precedence check. The symlink is required: the shim
# locates fm-gh.sh relative to its own real path, so a copy placed outside bin/ cannot
# find the wrapper. Read docs/no-mistakes-pr-credential.md before installing, because
# this shim is scoped to a PATH, not to a repository or a worktree, so every process
# resolving gh through that directory is affected.
#
# Credential-routed invocations, chosen because these are the two calls a
# fine-grained token is forbidden from and the pipeline's PR step makes both:
#   gh pr create ...
#   gh pr edit ...
# When either omits --repo/-R, the shim resolves the current no-mistakes gate to
# its registered repository record and appends that record's canonical push target:
# fork_url when configured, otherwise upstream_url. The registered checkout and its
# no-mistakes remote must corroborate the record. Missing, malformed, or contradictory
# evidence refuses the mutation so gh cannot infer a fork's parent repository.
# The CI monitor's exact `gh pr checks ... --json name,state,bucket,completedAt[,link]`
# vectors first try the real gh with the ambient narrow token. Only the known HTTP
# GraphQL personal-token denial for statusCheckRollup reaches fm-gh-ci-fallback.sh, which uses
# that SAME token to read the PR's exact head and workflow runs filtered by that SHA.
# It never reaches fm-gh.sh or config/gh-credential's broader token. Every other
# invocation execs the real gh unchanged, so the shim's default remains current behavior.
set -eu

# The merge capture boundary uses this side-effect-free probe to skip a shim from any
# Firstmate home, not only the source-relative copy it happens to be running from.
if [ "${FM_GH_SHIM_PROBE:-}" = 1 ] && [ "$#" -eq 1 ] \
  && [ "$1" = --firstmate-gh-shim-probe ]; then
  echo firstmate-gh-shim-v1
  exit 0
fi

# FM_GH_SHIM_ACTIVE keeps credential routing one-shot when the configured prefix
# resolves gh through this shim once more. A separate depth bound fails loudly if a
# stale shim, capture wrapper, or credential helper continues resolving gh recursively.
SHIM_DEPTH=${FM_GH_SHIM_DEPTH:-0}
case "$SHIM_DEPTH" in
  '' | *[!0-9]*)
    echo "fm-gh-shim: invalid recursion depth; refusing gh dispatch" >&2
    exit 70
    ;;
esac
if [ "$SHIM_DEPTH" -ge 2 ]; then
  echo "fm-gh-shim: recursion detected after two shim entries; inspect the credential prefix and installed gh targets" >&2
  exit 70
fi
export FM_GH_SHIM_DEPTH=$((SHIM_DEPTH + 1))

ROUTE=passthrough
if [ "${FM_GH_SHIM_ACTIVE:-}" != "1" ] && [ "${1:-}" = "pr" ]; then
  case "${2:-}" in
    create | edit) ROUTE=credential ;;
    checks) ROUTE=ci-candidate ;;
  esac
fi

SHIM_PATH="${BASH_SOURCE[0]}"
SHIM_DIR="$(cd "$(dirname "$SHIM_PATH")" && pwd)"

# resolve_path <path>: echo an absolute, symlink-resolved path, or the input when it
# cannot be resolved. Used only to compare candidates against this shim.
resolve_path() {
  local target=$1
  if command -v realpath > /dev/null 2>&1; then
    realpath "$target" 2> /dev/null || printf '%s\n' "$target"
  else
    local dir base
    dir=$(cd "$(dirname "$target")" 2> /dev/null && pwd) || {
      printf '%s\n' "$target"
      return 0
    }
    base=$(basename "$target")
    while [ -L "$dir/$base" ]; do
      local link
      link=$(readlink "$dir/$base") || break
      case "$link" in
        /*) dir=$(cd "$(dirname "$link")" && pwd) ;;
        *) dir=$(cd "$dir" && cd "$(dirname "$link")" && pwd) ;;
      esac
      base=$(basename "$link")
    done
    printf '%s\n' "$dir/$base"
  fi
}

SHIM_REAL=$(resolve_path "$SHIM_PATH")
# SHIM_DIR is where the shim was INVOKED from and is what must be skipped when
# searching PATH for the real gh. SHIM_SRC_DIR is where the shim's own file actually
# lives, which is the repo's bin/ when installed as a symlink, and is what locates
# fm-gh.sh. The two differ for every real installation, so neither can serve both roles.
SHIM_SRC_DIR="$(cd "$(dirname "$SHIM_REAL")" && pwd)"

# find_real_gh: echo the first executable named gh on PATH that is not this shim.
# Directory identity alone is not enough, because the shim may be installed under a
# path that resolves to a directory already on PATH, so each candidate is compared
# against the shim's own resolved path as well.
find_real_gh() {
  local entry candidate
  local IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/gh"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    [ "$(cd "$entry" 2> /dev/null && pwd)" = "$SHIM_DIR" ] && continue
    [ "$(resolve_path "$candidate")" = "$SHIM_REAL" ] && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

REAL_GH=$(find_real_gh) || {
  echo "fm-gh-shim: no real gh found on PATH beyond the shim directory ($SHIM_DIR)" >&2
  exit 127
}

pr_option_takes_value() {
  case "$1:$2" in
    create:-a | create:--assignee | \
      create:-B | create:--base | \
      create:-b | create:--body | \
      create:-F | create:--body-file | \
      create:-H | create:--head | \
      create:-l | create:--label | \
      create:-m | create:--milestone | \
      create:-p | create:--project | \
      create:--recover | \
      create:-r | create:--reviewer | \
      create:-T | create:--template | \
      create:-t | create:--title | \
      edit:--add-assignee | \
      edit:--add-label | \
      edit:--add-project | \
      edit:--add-reviewer | \
      edit:-B | edit:--base | \
      edit:-b | edit:--body | \
      edit:-F | edit:--body-file | \
      edit:-m | edit:--milestone | \
      edit:--remove-assignee | \
      edit:--remove-label | \
      edit:--remove-project | \
      edit:--remove-reviewer | \
      edit:-t | edit:--title) return 0 ;;
  esac
  return 1
}

short_option_has_repo() {
  local subcommand=$1 cluster=${2#-} option
  while [ -n "$cluster" ]; do
    option=${cluster%"${cluster#?}"}
    cluster=${cluster#?}
    [ "$option" = R ] && return 0
    case "$subcommand:$option" in
      create:a | create:B | create:b | create:F | create:H | create:l | \
        create:m | create:p | create:r | create:T | create:t | \
        edit:B | edit:b | edit:F | edit:m | edit:t) return 1 ;;
    esac
  done
  return 1
}

has_explicit_repo() {
  local subcommand=${2:-} arg skip_value=0
  shift 2
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    if [ "$skip_value" -eq 1 ]; then
      skip_value=0
      continue
    fi
    case "$arg" in
      --) return 1 ;;
      --repo | -R | --repo=* | -R?*) return 0 ;;
    esac
    case "$arg" in
      --*) ;;
      -?*) short_option_has_repo "$subcommand" "$arg" && return 0 ;;
    esac
    if pr_option_takes_value "$subcommand" "$arg"; then
      skip_value=1
    fi
  done
  return 1
}

# github_repo_slug <url>: print owner/name only for an unambiguous github.com URL.
github_repo_slug() {
  local url=$1 path
  case "$url" in
    https://github.com/* | http://github.com/* | ssh://git@github.com/*)
      path=${url#*://}
      path=${path#*/}
      ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [[ "$path" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
  printf '%s\n' "$path"
}

target_error() {
  printf 'fm-gh-shim: refusing credential-routed gh pr %s without --repo: %s\n' \
    "${2:-<unknown>}" "$1" >&2
}

# canonical_repo_slug: resolve the canonical GitHub push target from no-mistakes'
# repository registration. The database choice mirrors Repo.PushURL(): a configured
# fork_url wins, otherwise upstream_url is the delivery target. The gate identity and
# registered checkout corroborate that record; no remote name or ordering selects it.
canonical_repo_slug() {
  local git_common gate_dir gate_parent repo_id nm_home db record rest
  local working_path upstream_url fork_url canonical_url canonical_slug
  local registered_gate remote remote_url remote_slug found=0 action=${2:-}

  git_common=$(git rev-parse --git-common-dir 2> /dev/null) || {
    target_error "the current directory is not a no-mistakes gate checkout" "$action"
    return 1
  }
  case "$git_common" in
    /*) ;;
    *)
      git_common="$(git rev-parse --show-toplevel 2> /dev/null)/$git_common" || {
        target_error "cannot resolve the current checkout's common Git directory" "$action"
        return 1
      }
      ;;
  esac
  gate_dir=$(resolve_path "$git_common")
  gate_parent=$(dirname "$gate_dir")
  repo_id=$(basename "$gate_dir" .git)
  if [ "$(basename "$gate_parent")" != repos ] || \
    [ "$(basename "$gate_dir")" != "$repo_id.git" ] || \
    ! [[ "$repo_id" =~ ^[0-9a-f]{12}$ ]]; then
    target_error "the current checkout is not backed by a canonical no-mistakes repos/<id>.git gate" "$action"
    return 1
  fi

  nm_home=$(dirname "$gate_parent")
  db="$nm_home/state.sqlite"
  command -v sqlite3 > /dev/null 2>&1 || {
    target_error "sqlite3 is required to read the no-mistakes repository registration" "$action"
    return 1
  }
  [ -r "$db" ] || {
    target_error "no readable no-mistakes registration database at $db; run no-mistakes init from the registered checkout" "$action"
    return 1
  }
  record=$(sqlite3 -readonly -separator '|' "$db" \
    "SELECT working_path, upstream_url, COALESCE(fork_url, '') FROM repos WHERE id = '$repo_id';" 2> /dev/null) || {
    target_error "cannot read repository $repo_id from $db; run no-mistakes doctor" "$action"
    return 1
  }
  [ -n "$record" ] || {
    target_error "gate $gate_dir has no repository registration in $db; run no-mistakes init from the registered checkout" "$action"
    return 1
  }
  case "$record" in
    *$'\n'* | *'|'*'|'*'|'*)
      target_error "repository $repo_id has contradictory or malformed canonical target evidence in $db" "$action"
      return 1
      ;;
  esac
  working_path=${record%%|*}
  rest=${record#*|}
  upstream_url=${rest%%|*}
  fork_url=${rest#*|}
  [ -n "$working_path" ] && [ -n "$upstream_url" ] || {
    target_error "repository $repo_id has incomplete canonical target evidence in $db" "$action"
    return 1
  }
  canonical_url=$upstream_url
  [ -z "$fork_url" ] || canonical_url=$fork_url
  canonical_slug=$(github_repo_slug "$canonical_url") || {
    target_error "registered canonical target '$canonical_url' is not an unambiguous github.com repository URL" "$action"
    return 1
  }

  if [ ! -d "$working_path" ] || \
    ! git -C "$working_path" rev-parse --git-dir > /dev/null 2>&1; then
    target_error "registered checkout $working_path is unavailable; repair the no-mistakes repository registration" "$action"
    return 1
  fi
  registered_gate=$(git -C "$working_path" remote get-url no-mistakes 2> /dev/null) || {
    target_error "registered checkout $working_path has no no-mistakes remote proving gate $repo_id; run no-mistakes init" "$action"
    return 1
  }
  case "$registered_gate" in
    /*) ;;
    file://*) registered_gate=${registered_gate#file://} ;;
    *)
      target_error "registered checkout $working_path has a non-absolute no-mistakes remote; run no-mistakes init" "$action"
      return 1
      ;;
  esac
  if [ "$(resolve_path "$registered_gate")" != "$gate_dir" ]; then
    target_error "registered checkout $working_path points at a different no-mistakes gate than $gate_dir" "$action"
    return 1
  fi

  for remote in $(git -C "$working_path" remote 2> /dev/null); do
    while IFS= read -r remote_url; do
      remote_slug=$(github_repo_slug "$remote_url" 2> /dev/null) || continue
      [ "$remote_slug" = "$canonical_slug" ] && found=1
    done << EOF
$(git -C "$working_path" remote get-url --all "$remote" 2> /dev/null)
EOF
  done
  if [ "$found" -ne 1 ]; then
    target_error "registered canonical target '$canonical_slug' is absent from $working_path remotes; refresh the no-mistakes registration" "$action"
    return 1
  fi

  printf '%s\n' "$canonical_slug"
}

if [ "$ROUTE" = credential ]; then
  if ! has_explicit_repo "$@"; then
    REPO=$(canonical_repo_slug "$@") || exit 1
    PR_COMMAND=$1
    PR_ACTION=$2
    shift 2
    set -- "$PR_COMMAND" "$PR_ACTION" --repo "$REPO" "$@"
  fi
  export FM_GH_SHIM_ACTIVE=1
  exec "${FM_GH_SHIM_WRAPPER:-$SHIM_SRC_DIR/fm-gh.sh}" "$REAL_GH" "$@"
fi

CI_FALLBACK="$SHIM_SRC_DIR/fm-gh-ci-fallback.sh"
if [ "$ROUTE" = ci-candidate ] && [ -x "$CI_FALLBACK" ] && \
  "$CI_FALLBACK" --supports "$@"; then
  exec "${FM_GH_SHIM_CI_FALLBACK:-$CI_FALLBACK}" "$REAL_GH" "$@"
fi

exec "$REAL_GH" "$@"
