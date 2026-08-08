#!/usr/bin/env bash
# Configure and validate Firstmate's fork-main Git remote topology.
#
# Usage:
#   fm-fork-remotes.sh check [<repo>]
#       Require origin=<fork>, upstream=<official>, distinct URLs, main tracking
#       origin, rerere.enabled=true, and rerere.autoupdate=false.
#   fm-fork-remotes.sh plan <fork-url> <upstream-url> [<repo>]
#       Read only. Validate the requested migration and print the exact apply and
#       reverse commands. Never infers a fork owner or changes Git configuration.
#   fm-fork-remotes.sh apply <fork-url> <upstream-url> --confirm [--no-registration] [<repo>]
#       Migrate only an exact upstream-as-origin checkout, or validate an already
#       migrated one. Prints the reverse command before changing anything. Both
#       URLs must answer a read-only ls-remote preflight. The ordinary
#       no-mistakes registration must prove official remote plus personal fork
#       unchanged before and after migration. --no-registration is reserved for
#       provisioned remote code roots that never validate changes themselves.
#       Never force-pushes or changes a branch or working-tree file.
#   fm-fork-remotes.sh reverse <fork-url> <upstream-url> --confirm [<repo>]
#       Restore the official repository as origin and retain the personal fork as
#       a remote named fork. Never changes commits or working-tree files.
#   fm-fork-remotes.sh inherit <source-repo> <target-repo>
#       Provisioning-only convergence for a new standalone secondmate clone.
#       A linked worktree already shares the source config and is a no-op. An
#       unrelated target remote is refused, never overwritten.
#
# apply/reverse require the literal --confirm token because changing origin on a
# captain's operating checkout must be surfaced and approved, never performed as
# a side effect of startup or self-update. The remote-root-only
# --no-registration exception is an explicit provisioning input, not a fallback
# after a no-mistakes error. apply explicitly leaves
# rerere.autoupdate off: rerere may populate a repeated resolution in the working
# tree, but it must remain unstaged for review.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-fork-remotes: %s\n' "$*" >&2
  exit 1
}

quote_arg() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

repo_real() {
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

require_repo() {
  REPO=$(repo_real "$1") || die "not a directory: $1"
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a Git worktree: $REPO"
}

remote_url() {
  git -C "$1" remote get-url --all "$2" 2>/dev/null || true
}

remote_push_url() {
  git -C "$1" remote get-url --all --push "$2" 2>/dev/null || true
}

set_single_remote_url() {
  local repo=$1 name=$2 url=$3
  git -C "$repo" config --replace-all "remote.$name.url" "$url"
  git -C "$repo" config --unset-all "remote.$name.pushurl" >/dev/null 2>&1 || true
}

copy_remote_fetch() { # <source> <target> <remote>
  local source=$1 target=$2 remote=$3 refspec found=0
  git -C "$target" config --unset-all "remote.$remote.fetch" >/dev/null 2>&1 || true
  while IFS= read -r refspec || [ -n "$refspec" ]; do
    [ -n "$refspec" ] || continue
    git -C "$target" config --add "remote.$remote.fetch" "$refspec"
    found=1
  done < <(git -C "$source" config --get-all "remote.$remote.fetch" 2>/dev/null || true)
  [ "$found" -eq 1 ] || die "source $remote remote has no fetch refspec"
}

copy_remote_head() { # <source> <target> <remote>
  local source=$1 target=$2 remote=$3 source_head branch
  source_head=$(git -C "$source" symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  [ -n "$source_head" ] || return 0
  branch=${source_head#"refs/remotes/$remote/"}
  [ -n "$branch" ] && [ "$branch" != "$source_head" ] || die "source $remote HEAD is malformed"
  git -C "$target" symbolic-ref "refs/remotes/$remote/HEAD" "refs/remotes/$remote/$branch"
}

default_branch() {
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

print_apply_command() {
  quote_arg "$FM_ROOT/bin/fm-fork-remotes.sh"
  printf ' apply '
  quote_arg "$FORK_URL"
  printf ' '
  quote_arg "$UPSTREAM_URL"
  printf ' --confirm '
  quote_arg "$REPO"
  printf '\n'
}

print_reverse_command() {
  quote_arg "$FM_ROOT/bin/fm-fork-remotes.sh"
  printf ' reverse '
  quote_arg "$FORK_URL"
  printf ' '
  quote_arg "$UPSTREAM_URL"
  printf ' --confirm '
  quote_arg "$REPO"
  printf '\n'
}

validate_requested_urls() {
  case "$FORK_URL$UPSTREAM_URL" in
    *$'\n'*) die "remote URLs must not contain newlines" ;;
  esac
  [ -n "$FORK_URL" ] || die "fork URL is empty"
  [ -n "$UPSTREAM_URL" ] || die "upstream URL is empty"
  [ "$FORK_URL" != "$UPSTREAM_URL" ] || die "fork and upstream URLs must be distinct"
}

validate_topology() {
  local repo=$1 fork_url=$2 upstream_url=$3 branch branch_remote rerere_enabled rerere_autoupdate
  [ -n "$fork_url" ] || die "origin remote is missing"
  [ -n "$upstream_url" ] || die "upstream remote is missing"
  [ "$fork_url" != "$upstream_url" ] || die "origin and upstream resolve to the same URL"
  [ "$(remote_push_url "$repo" origin)" = "$fork_url" ] \
    || die "origin push URL does not exactly match its fetch URL"
  [ "$(remote_push_url "$repo" upstream)" = "$upstream_url" ] \
    || die "upstream push URL does not exactly match its fetch URL"
  branch=$(default_branch "$repo") || die "cannot determine the default branch"
  branch_remote=$(git -C "$repo" config --get "branch.$branch.remote" 2>/dev/null || true)
  [ "$branch_remote" = origin ] || die "$branch tracks '${branch_remote:-nothing}', expected origin"
  rerere_enabled=$(git -C "$repo" config --type=bool --get rerere.enabled 2>/dev/null || true)
  [ "$rerere_enabled" = true ] || die "rerere.enabled is not true"
  rerere_autoupdate=$(git -C "$repo" config --type=bool --get rerere.autoupdate 2>/dev/null || true)
  [ "$rerere_autoupdate" = false ] || die "rerere.autoupdate is not explicitly false"
  printf 'topology: ok origin=%s upstream=%s branch=%s rerere=enabled,autoupdate-off\n' \
    "$fork_url" "$upstream_url" "$branch"
}

preflight_url() {
  local label=$1 url=$2
  GIT_TERMINAL_PROMPT=0 git ls-remote --symref -- "$url" HEAD >/dev/null 2>&1 \
    || die "$label URL is unreachable or requires interactive authentication: $url"
}

no_mistakes_registration() { # <repo>, prints remote<TAB>fork
  local repo=$1 out remote fork
  command -v no-mistakes >/dev/null 2>&1 \
    || die "no-mistakes is required to prove the ordinary registration before migration"
  out=$(cd "$repo" && no-mistakes status 2>&1) \
    || die "no-mistakes status failed; shared service left untouched and migration refused"
  remote=$(printf '%s\n' "$out" | awk '$1 == "remote:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  fork=$(printf '%s\n' "$out" | awk '$1 == "fork:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  [ "$remote" = "$UPSTREAM_URL" ] \
    || die "ordinary no-mistakes registration remote is '${remote:-missing}', expected official upstream"
  [ "$fork" = "$FORK_URL" ] \
    || die "ordinary no-mistakes registration fork is '${fork:-missing}', expected personal fork"
  printf '%s\t%s\n' "$remote" "$fork"
}

configure_policy() {
  local repo=$1 branch
  branch=$(default_branch "$repo") || die "cannot determine the default branch"
  set_single_remote_url "$repo" origin "$FORK_URL"
  set_single_remote_url "$repo" upstream "$UPSTREAM_URL"
  git -C "$repo" config "branch.$branch.remote" origin
  git -C "$repo" config "branch.$branch.merge" "refs/heads/$branch"
  git -C "$repo" config rerere.enabled true
  git -C "$repo" config rerere.autoupdate false
}

cmd_check() {
  require_repo "${1:-$FM_ROOT}"
  validate_topology "$REPO" "$(remote_url "$REPO" origin)" "$(remote_url "$REPO" upstream)"
}

cmd_plan() {
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
  FORK_URL=$1
  UPSTREAM_URL=$2
  validate_requested_urls
  require_repo "${3:-$FM_ROOT}"
  local origin current_upstream
  origin=$(remote_url "$REPO" origin)
  current_upstream=$(remote_url "$REPO" upstream)
  if [ "$origin" = "$UPSTREAM_URL" ] && [ -z "$current_upstream" ]; then
    :
  elif [ "$origin" = "$FORK_URL" ] && [ "$current_upstream" = "$UPSTREAM_URL" ]; then
    :
  else
    die "refusing ambiguous topology: origin=${origin:-missing} upstream=${current_upstream:-missing}"
  fi
  printf 'plan: origin=%s upstream=%s\n' "$FORK_URL" "$UPSTREAM_URL"
  printf 'apply-command: '
  print_apply_command
  printf 'reverse-command: '
  print_reverse_command
}

cmd_apply() {
  [ "$#" -ge 3 ] && [ "$#" -le 5 ] || { usage >&2; exit 2; }
  FORK_URL=$1
  UPSTREAM_URL=$2
  [ "$3" = --confirm ] || die "apply requires the literal --confirm token after captain approval"
  shift 3
  local skip_registration=0 repo_arg=${1:-$FM_ROOT} origin current_upstream registration_before registration_after config_path config_backup
  if [ "${1:-}" = --no-registration ]; then
    skip_registration=1
    shift
    repo_arg=${1:-$FM_ROOT}
  fi
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  validate_requested_urls
  require_repo "$repo_arg"
  origin=$(remote_url "$REPO" origin)
  current_upstream=$(remote_url "$REPO" upstream)
  if ! { [ "$origin" = "$UPSTREAM_URL" ] && [ -z "$current_upstream" ]; } \
      && ! { [ "$origin" = "$FORK_URL" ] && [ "$current_upstream" = "$UPSTREAM_URL" ]; }; then
    die "refusing ambiguous topology: origin=${origin:-missing} upstream=${current_upstream:-missing}"
  fi
  if [ "$skip_registration" -eq 0 ]; then
    registration_before=$(no_mistakes_registration "$REPO")
  fi
  preflight_url fork "$FORK_URL"
  preflight_url upstream "$UPSTREAM_URL"
  printf 'reverse-command: '
  print_reverse_command
  if [ "$origin" = "$UPSTREAM_URL" ]; then
    config_path=$(git -C "$REPO" rev-parse --path-format=absolute --git-path config)
    [ -f "$config_path" ] && [ ! -L "$config_path" ] || die "Git config is unsafe"
    config_backup=$(mktemp "${TMPDIR:-/tmp}/fm-fork-apply-config.XXXXXX") || die "cannot snapshot Git config"
    cp -p "$config_path" "$config_backup" || { rm -f "$config_backup"; die "cannot snapshot Git config"; }
    FM_FORK_APPLY_REPO=$REPO
    FM_FORK_APPLY_CONFIG=$config_path
    FM_FORK_APPLY_BACKUP=$config_backup
    FM_FORK_APPLY_COMMITTED=0
    apply_status=0
    trap '
      apply_status=$?
      trap - EXIT HUP INT TERM
      if [ "${FM_FORK_APPLY_COMMITTED:-0}" -ne 1 ]; then
        if git -C "$FM_FORK_APPLY_REPO" remote get-url upstream >/dev/null 2>&1; then
          git -C "$FM_FORK_APPLY_REPO" remote remove origin >/dev/null 2>&1 || true
          git -C "$FM_FORK_APPLY_REPO" remote rename upstream origin >/dev/null 2>&1 || true
        fi
        cp -p "$FM_FORK_APPLY_BACKUP" "$FM_FORK_APPLY_CONFIG" 2>/dev/null || true
      fi
      rm -f "$FM_FORK_APPLY_BACKUP" 2>/dev/null || true
      exit "$apply_status"
    ' EXIT
    trap 'exit 1' HUP INT TERM
    git -C "$REPO" remote rename origin upstream
    git -C "$REPO" remote add origin "$FORK_URL" \
      || die "could not add fork as origin; original topology will be restored"
  fi
  configure_policy "$REPO"
  git -C "$REPO" fetch --quiet --prune origin || die "fork fetch failed after topology configuration"
  git -C "$REPO" fetch --quiet --prune upstream || die "upstream fetch failed after topology configuration"
  git -C "$REPO" remote set-head origin --auto >/dev/null 2>&1 || true
  git -C "$REPO" remote set-head upstream --auto >/dev/null 2>&1 || true
  validate_topology "$REPO" "$(remote_url "$REPO" origin)" "$(remote_url "$REPO" upstream)"
  if [ "$skip_registration" -eq 0 ]; then
    registration_after=$(no_mistakes_registration "$REPO")
    [ "$registration_after" = "$registration_before" ] \
      || die "ordinary no-mistakes registration changed during migration; original Git topology will be restored"
  fi
  if [ "$origin" = "$UPSTREAM_URL" ]; then
    FM_FORK_APPLY_COMMITTED=1
    rm -f "$config_backup"
    trap - EXIT HUP INT TERM
  fi
}

cmd_reverse() {
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
  FORK_URL=$1
  UPSTREAM_URL=$2
  [ "$3" = --confirm ] || die "reverse requires the literal --confirm token"
  validate_requested_urls
  require_repo "${4:-$FM_ROOT}"
  [ "$(remote_url "$REPO" origin)" = "$FORK_URL" ] \
    || die "origin is not the expected fork; refusing reverse"
  [ "$(remote_url "$REPO" upstream)" = "$UPSTREAM_URL" ] \
    || die "upstream is not the expected official repository; refusing reverse"
  [ -z "$(remote_url "$REPO" fork)" ] || die "a remote named fork already exists"
  set_single_remote_url "$REPO" origin "$FORK_URL"
  set_single_remote_url "$REPO" upstream "$UPSTREAM_URL"
  git -C "$REPO" remote rename origin fork
  if ! git -C "$REPO" remote rename upstream origin; then
    git -C "$REPO" remote rename fork origin >/dev/null 2>&1 || true
    die "could not restore upstream as origin; restored fork as origin"
  fi
  local branch
  branch=$(default_branch "$REPO") || branch=main
  git -C "$REPO" config "branch.$branch.remote" origin
  git -C "$REPO" config "branch.$branch.merge" "refs/heads/$branch"
  printf 'reversed: origin=%s fork=%s branch=%s\n' "$UPSTREAM_URL" "$FORK_URL" "$branch"
}

cmd_inherit() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  local source_input source_real target_real source_origin source_upstream target_origin source_common target_common branch target_config backup_config
  source_input=$1
  source_real=$(repo_real "$1") || die "source is not a directory: $1"
  target_real=$(repo_real "$2") || die "target is not a directory: $2"
  git -C "$source_real" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "source is not a Git worktree"
  source_origin=$(remote_url "$source_real" origin)
  source_upstream=$(remote_url "$source_real" upstream)
  [ -n "$source_upstream" ] || { printf 'inherit: classic single-origin topology unchanged\n'; return 0; }
  git -C "$target_real" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "target is not a Git worktree"
  [ -n "$source_origin" ] && [ "$source_origin" != "$source_upstream" ] \
    || die "source fork topology is invalid"
  validate_topology "$source_real" "$source_origin" "$source_upstream" >/dev/null
  source_common=$(common_dir "$source_real")
  target_common=$(common_dir "$target_real")
  if [ -n "$source_common" ] && [ "$source_common" = "$target_common" ]; then
    printf 'inherit: linked worktree already shares fork topology\n'
    return 0
  fi
  target_origin=$(remote_url "$target_real" origin)
  case "$target_origin" in
    "$source_input"|"$source_real"|"$source_origin") ;;
    *) die "target origin is unrelated (${target_origin:-missing}); refusing overwrite" ;;
  esac
  if [ -n "$(remote_url "$target_real" upstream)" ] \
      && [ "$(remote_url "$target_real" upstream)" != "$source_upstream" ]; then
    die "target upstream is unrelated; refusing overwrite"
  fi
  target_config=$(git -C "$target_real" rev-parse --path-format=absolute --git-path config)
  [ -f "$target_config" ] && [ ! -L "$target_config" ] || die "target Git config is unsafe"
  backup_config=$(mktemp "${TMPDIR:-/tmp}/fm-fork-inherit-config.XXXXXX") || die "cannot snapshot target Git config"
  cp -p "$target_config" "$backup_config" || { rm -f "$backup_config"; die "cannot snapshot target Git config"; }
  FM_FORK_INHERIT_CONFIG=$target_config
  FM_FORK_INHERIT_BACKUP=$backup_config
  FM_FORK_INHERIT_COMMITTED=0
  inherit_status=0
  trap '
    inherit_status=$?
    trap - EXIT HUP INT TERM
    if [ "${FM_FORK_INHERIT_COMMITTED:-0}" -ne 1 ]; then
      cp -p "$FM_FORK_INHERIT_BACKUP" "$FM_FORK_INHERIT_CONFIG" 2>/dev/null || true
    fi
    rm -f "$FM_FORK_INHERIT_BACKUP" 2>/dev/null || true
    exit "$inherit_status"
  ' EXIT
  trap 'exit 1' HUP INT TERM
  if [ -z "$(remote_url "$target_real" upstream)" ]; then
    git -C "$target_real" remote add upstream "$source_upstream"
  fi
  set_single_remote_url "$target_real" origin "$source_origin"
  set_single_remote_url "$target_real" upstream "$source_upstream"
  copy_remote_fetch "$source_real" "$target_real" origin
  copy_remote_fetch "$source_real" "$target_real" upstream
  branch=$(default_branch "$target_real") || branch=$(default_branch "$source_real") || branch=main
  git -C "$target_real" config "branch.$branch.remote" origin
  git -C "$target_real" config "branch.$branch.merge" "refs/heads/$branch"
  git -C "$target_real" config rerere.enabled true
  git -C "$target_real" config rerere.autoupdate false
  copy_remote_head "$source_real" "$target_real" origin
  copy_remote_head "$source_real" "$target_real" upstream
  validate_topology "$target_real" "$(remote_url "$target_real" origin)" "$(remote_url "$target_real" upstream)"
  FM_FORK_INHERIT_COMMITTED=1
  rm -f "$backup_config"
  trap - EXIT HUP INT TERM
}

MODE=${1:-}
[ "$#" -eq 0 ] || shift
case "$MODE" in
  check) cmd_check "$@" ;;
  plan) cmd_plan "$@" ;;
  apply) cmd_apply "$@" ;;
  reverse) cmd_reverse "$@" ;;
  inherit) cmd_inherit "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
