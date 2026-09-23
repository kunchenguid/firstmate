#!/usr/bin/env bash
# Bounded GitHub write entry point for Firstmate delivery.
#
# Usage:
#   fm-github-write.sh direct-pr <task-id> --title <title> --body-file <path>
#   fm-github-write.sh merge <task-id> <canonical-pr-url>
#   fm-github-write.sh --help
#
# direct-pr derives the task worktree and project from this home's
# state/<task-id>.meta, requires mode=direct-PR, requires the current directory
# to be that exact isolated worktree on branch fm/<task-id>, verifies the
# worktree and recorded project have identical GitHub origin configuration,
# disables Git hooks, pushes only HEAD to that branch without force, and creates
# or updates only that branch's pull request against the origin's default branch.
# The caller supplies PR prose, never repository, branch, remote, base, or PR
# coordinates. The body must be a bounded regular file inside the task worktree.
#
# merge requires the task's recorded yolo=on posture, accepts no forge flags,
# verifies the reviewed fm-pr-merge.sh digest, and then executes that existing
# guarded merge path unchanged. Its canonical-PR, task identity, lease,
# captain-hold, live-head, green-check, merge-authority, and outcome guards stay
# authoritative. Updating fm-pr-merge.sh requires updating the digest below;
# that changes this script and therefore invalidates the Blessed Script wrapper.
#
# On macOS with Automic Vault installed, every operation re-enters through the
# adjacent fm-github-write-av.sh Blessed Script unless that script set the
# private FM_GITHUB_WRITE_ACTIVE marker. The Blessed Script grants only the gh
# Write and SSH authentication capabilities this reviewed operation needs.
# Worker and firstmate launchers remain unendorsed, so each invocation uses
# Automic Vault's attended Approval policy.
# On hosts without Automic Vault, this script preserves the same validation but
# uses the host's existing GitHub and SSH authentication.
#
# FM_AUTOMIC_VAULT_BIN exists for deterministic tests and unusual installations.
# Pointing it elsewhere cannot grant authority: only an actual active Blessing
# can authorize the gated child operations.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="$FM_HOME/state"
AV_BIN=${FM_AUTOMIC_VAULT_BIN:-/usr/local/bin/av}
GH_AXI_BIN=${FM_GITHUB_WRITE_GH_AXI_BIN:-gh-axi}
EXPECTED_PR_MERGE_SHA256='4d46491db94abeaaf21b4b16caaa76d74ff4c48e5c6cc60de92eb41485417d3f'

usage() {
  cat <<'EOF'
usage:
  fm-github-write.sh direct-pr <task-id> --title <title> --body-file <path>
  fm-github-write.sh merge <task-id> <canonical-pr-url>
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

if [ "${FM_GITHUB_WRITE_ACTIVE:-0}" != 1 ] && [ -x "$AV_BIN" ]; then
  GH_AXI_BIN=$(command -v gh-axi 2>/dev/null || true)
  [ -n "$GH_AXI_BIN" ] || die 'direct GitHub delivery requires gh-axi on PATH'
  FM_GITHUB_WRITE_GH_AXI_BIN=$GH_AXI_BIN
  export FM_GITHUB_WRITE_GH_AXI_BIN
  exec "$SCRIPT_DIR/fm-github-write-av.sh" "$@"
fi

valid_task_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

single_meta_value() { # <meta> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$meta") || return 1
  value=${value#*=}
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

sha256_file() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die 'SHA-256 tool is unavailable'
  fi
}

validate_meta() { # <id>
  local id=$1
  valid_task_id "$id" || die 'invalid task id'
  META="$STATE/$id.meta"
  [ -f "$META" ] && [ ! -L "$META" ] && [ -r "$META" ] \
    || die "task $id metadata is unavailable"
  KIND=$(single_meta_value "$META" kind) || die "task $id metadata has no unique kind"
  MODE=$(single_meta_value "$META" mode) || die "task $id metadata has no unique mode"
  WORKTREE=$(single_meta_value "$META" worktree) || die "task $id metadata has no unique worktree"
  PROJECT=$(single_meta_value "$META" project) || die "task $id metadata has no unique project"
  [ "$KIND" = ship ] || die "task $id is kind=$KIND, not a ship task"
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || die "task $id worktree is unavailable"
  [ -d "$PROJECT" ] && [ ! -L "$PROJECT" ] || die "task $id project is unavailable"
  WORKTREE=$(cd "$WORKTREE" && pwd -P) || die "task $id worktree cannot be resolved"
  PROJECT=$(cd "$PROJECT" && pwd -P) || die "task $id project cannot be resolved"
}

git_config_one() { # <repo> <key>
  local repo=$1 key=$2 values count
  values=$(git -C "$repo" config --get-all "$key" 2>/dev/null || true)
  count=$(printf '%s\n' "$values" | awk 'NF { n++ } END { print n + 0 }')
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$values"
}

parse_github_remote() { # <url>; sets REMOTE_OWNER REMOTE_REPO REMOTE_SSH
  local url=$1 path
  REMOTE_OWNER=
  REMOTE_REPO=
  REMOTE_SSH=
  case "$url" in
    git@github.com:*) path=${url#git@github.com:} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    https://github.com/*) path=${url#https://github.com/} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  case "$path" in
    */*) ;;
    *) return 1 ;;
  esac
  REMOTE_OWNER=${path%%/*}
  REMOTE_REPO=${path#*/}
  case "$REMOTE_OWNER/$REMOTE_REPO" in
    *'/'*'/'*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  [ -n "$REMOTE_OWNER" ] && [ -n "$REMOTE_REPO" ] || return 1
  REMOTE_SSH="ssh://git@github.com/$REMOTE_OWNER/$REMOTE_REPO.git"
}

project_origins() {
  local project=$1 fetch push
  fetch=$(git_config_one "$project" remote.origin.url) \
    || die 'recorded project must have exactly one local remote.origin.url'
  push=$(git -C "$project" config --get-all remote.origin.pushurl 2>/dev/null || true)
  if [ -z "$push" ]; then
    push=$fetch
  elif [ "$(printf '%s\n' "$push" | awk 'NF { n++ } END { print n + 0 }')" -ne 1 ]; then
    die 'recorded project must have at most one local remote.origin.pushurl'
  fi
  parse_github_remote "$fetch" || die 'recorded project origin must be an exact GitHub SSH or HTTPS repository URL'
  BASE_OWNER=$REMOTE_OWNER
  BASE_REPO=$REMOTE_REPO
  BASE_URL=$fetch
  parse_github_remote "$push" || die 'recorded project push origin must be an exact GitHub SSH or HTTPS repository URL'
  PUSH_OWNER=$REMOTE_OWNER
  PUSH_REPO=$REMOTE_REPO
  PUSH_URL=$push
  PUSH_SSH=$REMOTE_SSH
  [ "$BASE_REPO" = "$PUSH_REPO" ] \
    || die 'recorded project fetch and push origins must use the same repository name'
}

validate_worktree_identity() { # <id>
  local id=$1 cwd top branch head wt_fetch wt_push default_ref
  cwd=$(pwd -P)
  [ "$cwd" = "$WORKTREE" ] || die "direct-PR must run from task $id recorded worktree"
  top=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$WORKTREE" ] \
    || die "task $id worktree is not its exact git worktree root"
  branch=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" = "fm/$id" ] || die "task $id must be on branch fm/$id, not ${branch:-detached HEAD}"
  head=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null || true)
  case "$head" in [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) ;; *) die 'task branch HEAD is unreadable' ;; esac
  [ "${#head}" -eq 40 ] || die 'task branch HEAD is not a full SHA-1 commit'
  wt_fetch=$(git_config_one "$WORKTREE" remote.origin.url) \
    || die 'task worktree must have exactly one local remote.origin.url'
  wt_push=$(git -C "$WORKTREE" config --get-all remote.origin.pushurl 2>/dev/null || true)
  [ -n "$wt_push" ] || wt_push=$wt_fetch
  [ "$wt_fetch" = "$BASE_URL" ] && [ "$wt_push" = "$PUSH_URL" ] \
    || die 'task worktree origin does not match its recorded project origin'
  default_ref=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  case "$default_ref" in origin/?*) BASE_BRANCH=${default_ref#origin/} ;; *) die 'recorded project has no verified origin default branch' ;; esac
  [ "$BASE_BRANCH" != "$branch" ] || die 'task branch cannot be the default branch'
  TASK_BRANCH=$branch
}

validate_title() {
  local title=$1
  [ -n "$title" ] && [ "${#title}" -le 256 ] || die 'PR title must contain 1 to 256 characters'
  [ "$(printf '%s' "$title" | LC_ALL=C tr -d '\11\40-\176')" = '' ] \
    || die 'PR title must be one printable line'
}

reject_push_url_rewrites() {
  local rewrites line key prefix
  rewrites=$(git -C "$WORKTREE" config --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%% *}
    prefix=${line#* }
    [ "$key" != "$line" ] && [ -n "$prefix" ] \
      || die 'Git URL rewrite configuration is malformed; refusing the reviewed push'
    case "$PUSH_SSH" in
      "$prefix"*) die "Git URL rewrite $key would change the verified push destination" ;;
    esac
  done <<EOF
$rewrites
EOF
}

github_pr_rows() {
  local head_query base_query endpoint output header expected rows line number url
  head_query=$(jq -rn --arg value "$PUSH_OWNER:$TASK_BRANCH" '$value | @uri') \
    || die 'could not encode the verified pull request head'
  base_query=$(jq -rn --arg value "$BASE_BRANCH" '$value | @uri') \
    || die 'could not encode the verified pull request base'
  endpoint="/repos/$BASE_OWNER/$BASE_REPO/pulls?state=open&per_page=2&head=$head_query&base=$base_query"
  output=$("$GH_AXI_BIN" api "$endpoint" --jq '[.[] | {number, url: .html_url}]' --full) \
    || die 'could not inspect the task branch pull request'
  [ "$output" != '[]' ] || return 0
  header=${output%%$'\n'*}
  expected=$(printf '%s\n' "$header" | sed -n 's/^\[\([0-9][0-9]*\)\]{number,url}:$/\1/p')
  [ -n "$expected" ] || die 'gh-axi returned an unexpected pull request list shape'
  rows=${output#*$'\n'}
  [ "$rows" != "$output" ] || die 'gh-axi omitted the expected pull request rows'
  [ "$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n + 0 }')" -eq "$expected" ] \
    || die 'gh-axi pull request count did not match its rows'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    number=${line#  }
    number=${number%%,*}
    url=${line#*,}
    url=${url#\"}
    url=${url%\"}
    case "$number" in ''|*[!0-9]*) die 'matching pull request number is invalid' ;; esac
    [ "$url" = "https://github.com/$BASE_OWNER/$BASE_REPO/pull/$number" ] \
      || die 'matching pull request URL does not match the verified project'
    printf '%s\t%s\n' "$number" "$url"
  done <<EOF
$rows
EOF
}

validate_body_file() { # <path>
  local input=$1 parent file size
  [ -n "$input" ] || die '--body-file requires a path'
  [ -f "$input" ] && [ ! -L "$input" ] && [ -r "$input" ] || die 'PR body must be a readable regular non-symlink file'
  parent=$(cd "$(dirname "$input")" && pwd -P) || die 'PR body parent cannot be resolved'
  file="$parent/$(basename "$input")"
  case "$file" in "$WORKTREE"/*) ;; *) die 'PR body file must be inside the task worktree' ;; esac
  size=$(wc -c < "$file" | tr -d '[:space:]')
  [ "$size" -le 1048576 ] || die 'PR body file exceeds 1 MiB'
  BODY_FILE=$file
}

run_direct_pr() {
  local id=${1:-} title='' body='' existing='' line_count number url output
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title)
        [ -n "${2:-}" ] || die '--title requires a value'
        [ -z "$title" ] || die '--title may be specified only once'
        title=$2
        shift 2
        ;;
      --body-file)
        [ -n "${2:-}" ] || die '--body-file requires a path'
        [ -z "$body" ] || die '--body-file may be specified only once'
        body=$2
        shift 2
        ;;
      *) die "unknown direct-pr argument: $1" ;;
    esac
  done
  validate_meta "$id"
  [ "$MODE" = direct-PR ] || die "task $id is mode=$MODE, not direct-PR"
  project_origins "$PROJECT"
  validate_worktree_identity "$id"
  reject_push_url_rewrites
  validate_title "$title"
  validate_body_file "$body"
  [ -x "$(command -v "$GH_AXI_BIN" 2>/dev/null || true)" ] || die 'direct-PR requires gh-axi on PATH'
  command -v jq >/dev/null 2>&1 || die 'direct-PR requires jq on PATH'

  # The fixed SSH URL avoids caller-controlled remote names and Git URL rewrite
  # rules. Hooks are disabled so project code cannot run with the Blessing's
  # capabilities. The exact non-force branch refspec is the only write.
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_SSH_COMMAND='/usr/bin/ssh -F /dev/null -o HostName=github.com -o User=git' \
    git -C "$WORKTREE" -c core.hooksPath=/dev/null -c protocol.ext.allow=never \
      push --porcelain "$PUSH_SSH" "HEAD:refs/heads/$TASK_BRANCH" >&2

  existing=$(github_pr_rows)
  line_count=$(printf '%s\n' "$existing" | awk 'NF { n++ } END { print n + 0 }')
  [ "$line_count" -le 1 ] || die 'more than one open pull request matches the task branch'
  if [ "$line_count" -eq 1 ]; then
    number=${existing%%$'\t'*}
    url=${existing#*$'\t'}
    case "$number" in ''|*[!0-9]*) die 'matching pull request number is invalid' ;; esac
    [ "$url" = "https://github.com/$BASE_OWNER/$BASE_REPO/pull/$number" ] \
      || die 'matching pull request URL does not match the verified project'
    "$GH_AXI_BIN" pr edit "$number" --repo "$BASE_OWNER/$BASE_REPO" \
      --title "$title" --body-file "$BODY_FILE" >/dev/null
  else
    output=$("$GH_AXI_BIN" pr create --repo "$BASE_OWNER/$BASE_REPO" --base "$BASE_BRANCH" \
      --head "$PUSH_OWNER:$TASK_BRANCH" --title "$title" --body-file "$BODY_FILE") \
      || die 'could not create the task branch pull request'
    url=$(printf '%s\n' "$output" | grep -Eo "https://github.com/$BASE_OWNER/$BASE_REPO/pull/[0-9]+" | head -1 || true)
    case "$url" in
      "https://github.com/$BASE_OWNER/$BASE_REPO/pull/"*) ;;
      *) die 'created pull request did not return a canonical URL for the verified project' ;;
    esac
  fi
  printf '%s\n' "$url"
}

run_merge() {
  local id=${1:-} url=${2:-} actual yolo
  [ "$#" -eq 2 ] || die 'merge accepts exactly a task id and canonical PR URL'
  validate_meta "$id"
  case "$MODE" in no-mistakes|direct-PR) ;; *) die "task $id mode=$MODE has no GitHub PR merge path" ;; esac
  yolo=$(single_meta_value "$META" yolo) || die "task $id metadata has no unique yolo posture"
  [ "$yolo" = on ] || die "task $id does not carry standing autonomous merge authority"
  actual=$(sha256_file "$SCRIPT_DIR/fm-pr-merge.sh")
  [ "$actual" = "$EXPECTED_PR_MERGE_SHA256" ] \
    || die 'fm-pr-merge.sh changed after the reviewed GitHub-write declaration; update the bound digest and re-bless before merging'
  exec "$SCRIPT_DIR/fm-pr-merge.sh" "$id" "$url"
}

case "${1:-}" in
  direct-pr) shift; run_direct_pr "$@" ;;
  merge) shift; run_merge "$@" ;;
  *) usage >&2; exit 2 ;;
esac
