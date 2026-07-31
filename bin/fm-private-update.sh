#!/usr/bin/env bash
# Safely integrate a configured public upstream into private origin/main.
#
# This is the private-distribution half of /updatefirstmate.
# bin/fm-update.sh invokes it only when the active home has the local,
# gitignored config/private-upstream file.
# An absent config file is not an error and is handled by fm-update.sh's legacy
# origin-only fast-forward path without invoking this script.
#
# Config schema (exactly these three key=value records, comments and blank lines
# allowed):
#   private-origin-url=<expected fetch and push URL for remote origin>
#   public-upstream=<remote>/<branch>
#   public-upstream-url=<expected fetch URL for that remote>
#
# Values cannot contain whitespace.
# The public remote must not be origin, its fetch URL must match the declared
# public URL, and its only effective push URL must be the inert sentinel
# no_push://read-only.
# Origin must have exactly one effective fetch URL and one effective push URL,
# both matching the declared private URL.
# The declared private and public URLs must be different after normalizing the
# common GitHub HTTPS/SSH spellings and optional .git suffix.
# These checks fail closed before any network or checkout mutation so the
# integration result cannot accidentally be published to the public remote or
# an old public fork.
#
# The running checkout must be clean and on main.
# All network, merge, and validation work occurs in a fresh clone beneath
# state/private-update-evidence/.
# The clone fetches the configured public branch, refuses when running main has
# commits absent from private origin/main, merges the public tip into the cloned
# private main without forcing or rewriting, then runs:
#   bin/fm-lint.sh
#   bin/fm-test-run.sh --all
# Validation must leave the clone clean and its integrated HEAD unchanged.
# Only then is HEAD pushed without force to the declared private URL's main.
# A concurrent remote advance therefore fails as a normal non-fast-forward.
#
# Successful and no-op clones are removed.
# A clone is preserved with logs after divergence, merge conflict, failed
# validation, changed validation state, verification failure, or push failure;
# the reported evidence path is safe to inspect and private origin/main plus the
# running checkout remain unchanged.
#
# Output:
#   private-upstream: already current at <short-sha>
#   private-upstream: published <old>..<new> from <remote>/<branch>
#   private-upstream: stopped: <reason>
#   private-upstream: stopped: <reason>; evidence: <absolute-path>
#
# Usage: fm-private-update.sh [--help]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG_DIR/private-upstream"
READ_ONLY_PUSH_URL='no_push://read-only'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

stop_update() {
  printf 'private-upstream: stopped: %s\n' "$*" >&2
  exit 1
}

stop_with_evidence() {
  printf 'private-upstream: stopped: %s; evidence: %s\n' "$1" "$RUN_DIR" >&2
  exit 1
}

canonical_remote_url() {
  local value=$1 path
  case "$value" in
    git@github.com:*)
      path=${value#git@github.com:}
      value="github.com/$path"
      ;;
    ssh://git@github.com/*)
      path=${value#ssh://git@github.com/}
      value="github.com/$path"
      ;;
    https://github.com/*)
      path=${value#https://github.com/}
      value="github.com/$path"
      ;;
    http://github.com/*)
      path=${value#http://github.com/}
      value="github.com/$path"
      ;;
  esac
  value=${value%/}
  value=${value%.git}
  printf '%s\n' "$value"
}

single_remote_url() {
  local dir=$1 remote=$2 mode=$3 urls count
  if [ "$mode" = push ]; then
    urls=$(git -C "$dir" remote get-url --push --all "$remote" 2>/dev/null) || return 1
  else
    urls=$(git -C "$dir" remote get-url --all "$remote" 2>/dev/null) || return 1
  fi
  count=$(printf '%s\n' "$urls" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || return 2
  printf '%s\n' "$urls"
}

read_config() {
  local line key value seen_private=0 seen_public=0 seen_public_url=0
  PRIVATE_ORIGIN_URL=''
  PUBLIC_UPSTREAM=''
  PUBLIC_UPSTREAM_URL=''

  [ -f "$CONFIG_FILE" ] || stop_update "config/private-upstream is not a regular file"
  [ ! -L "$CONFIG_FILE" ] || stop_update "config/private-upstream must not be a symlink"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) stop_update "invalid config/private-upstream record: $line" ;;
    esac
    [ -n "$value" ] || stop_update "empty $key in config/private-upstream"
    case "$value" in
      *[[:space:]]*) stop_update "$key cannot contain whitespace" ;;
    esac
    case "$key" in
      private-origin-url)
        [ "$seen_private" -eq 0 ] || stop_update "duplicate private-origin-url"
        PRIVATE_ORIGIN_URL=$value
        seen_private=1
        ;;
      public-upstream)
        [ "$seen_public" -eq 0 ] || stop_update "duplicate public-upstream"
        PUBLIC_UPSTREAM=$value
        seen_public=1
        ;;
      public-upstream-url)
        [ "$seen_public_url" -eq 0 ] || stop_update "duplicate public-upstream-url"
        PUBLIC_UPSTREAM_URL=$value
        seen_public_url=1
        ;;
      *) stop_update "unknown config/private-upstream key: $key" ;;
    esac
  done < "$CONFIG_FILE"

  [ "$seen_private" -eq 1 ] || stop_update "missing private-origin-url"
  [ "$seen_public" -eq 1 ] || stop_update "missing public-upstream"
  [ "$seen_public_url" -eq 1 ] || stop_update "missing public-upstream-url"

  case "$PUBLIC_UPSTREAM" in
    */*)
      UPSTREAM_REMOTE=${PUBLIC_UPSTREAM%%/*}
      UPSTREAM_REF=${PUBLIC_UPSTREAM#*/}
      ;;
    *) stop_update "public-upstream must be <remote>/<branch>" ;;
  esac
  case "$UPSTREAM_REMOTE" in
    ''|*[!A-Za-z0-9._-]*) stop_update "invalid public upstream remote name" ;;
  esac
  [ "$UPSTREAM_REMOTE" != origin ] || stop_update "public upstream remote must not be origin"
  git check-ref-format "refs/heads/$UPSTREAM_REF" >/dev/null 2>&1 \
    || stop_update "invalid public upstream branch: $UPSTREAM_REF"
}

validate_remote_roles() {
  local origin_fetch origin_push upstream_fetch upstream_push
  local expected_private expected_public actual_origin_fetch actual_origin_push actual_upstream

  origin_fetch=$(single_remote_url "$FM_ROOT" origin fetch)
  case $? in
    0) ;;
    1) stop_update "origin has no usable fetch URL" ;;
    *) stop_update "origin must have exactly one effective fetch URL" ;;
  esac
  origin_push=$(single_remote_url "$FM_ROOT" origin push)
  case $? in
    0) ;;
    1) stop_update "origin has no usable push URL" ;;
    *) stop_update "origin must have exactly one effective push URL" ;;
  esac
  upstream_fetch=$(single_remote_url "$FM_ROOT" "$UPSTREAM_REMOTE" fetch)
  case $? in
    0) ;;
    1) stop_update "$UPSTREAM_REMOTE has no usable fetch URL" ;;
    *) stop_update "$UPSTREAM_REMOTE must have exactly one effective fetch URL" ;;
  esac
  upstream_push=$(single_remote_url "$FM_ROOT" "$UPSTREAM_REMOTE" push)
  case $? in
    0) ;;
    1) stop_update "$UPSTREAM_REMOTE has no disabled push URL" ;;
    *) stop_update "$UPSTREAM_REMOTE must have exactly one disabled push URL" ;;
  esac

  expected_private=$(canonical_remote_url "$PRIVATE_ORIGIN_URL")
  expected_public=$(canonical_remote_url "$PUBLIC_UPSTREAM_URL")
  actual_origin_fetch=$(canonical_remote_url "$origin_fetch")
  actual_origin_push=$(canonical_remote_url "$origin_push")
  actual_upstream=$(canonical_remote_url "$upstream_fetch")

  [ "$expected_private" != "$expected_public" ] \
    || stop_update "private origin and public upstream URLs must be different"
  [ "$actual_origin_fetch" = "$expected_private" ] \
    || stop_update "origin fetch URL does not match private-origin-url"
  [ "$actual_origin_push" = "$expected_private" ] \
    || stop_update "origin push URL does not match private-origin-url"
  [ "$actual_upstream" = "$expected_public" ] \
    || stop_update "$UPSTREAM_REMOTE fetch URL does not match public-upstream-url"
  [ "$upstream_push" = "$READ_ONLY_PUSH_URL" ] \
    || stop_update "$UPSTREAM_REMOTE push URL must be $READ_ONLY_PUSH_URL"
}

remove_success_clone() {
  case "$RUN_DIR" in
    "$EVIDENCE_ROOT"/run.*) rm -rf -- "$RUN_DIR" ;;
    *) stop_with_evidence "refused to remove unexpected success clone path" ;;
  esac
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || { usage; exit 1; }

read_config

[ -d "$FM_ROOT" ] || stop_update "firstmate root is not a directory"
git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || stop_update "firstmate root is not a git checkout"
[ "$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = main ] \
  || stop_update "running firstmate must be on main"
[ -z "$(git -C "$FM_ROOT" status --porcelain 2>/dev/null)" ] \
  || stop_update "running firstmate has a dirty working tree"

validate_remote_roles

LOCAL_HEAD=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) \
  || stop_update "cannot read running main"
EVIDENCE_ROOT="$STATE/private-update-evidence"
mkdir -p "$EVIDENCE_ROOT" || stop_update "cannot create private update evidence directory"
EVIDENCE_ROOT=$(cd "$EVIDENCE_ROOT" && pwd -P) \
  || stop_update "cannot resolve private update evidence directory"
RUN_DIR=$(mktemp -d "$EVIDENCE_ROOT/run.XXXXXX") \
  || stop_update "cannot create disposable integration clone"
REPO_DIR="$RUN_DIR/repo"
LOG_FILE="$RUN_DIR/integration.log"
VALIDATION_LOG="$RUN_DIR/validation.log"
PUSH_LOG="$RUN_DIR/push.log"
umask 077

{
  printf 'running-main=%s\n' "$LOCAL_HEAD"
  printf 'private-origin-url=%s\n' "$PRIVATE_ORIGIN_URL"
  printf 'public-upstream=%s\n' "$PUBLIC_UPSTREAM"
  printf 'public-upstream-url=%s\n' "$PUBLIC_UPSTREAM_URL"
} > "$LOG_FILE"

if ! git clone --quiet --single-branch --branch main "$PRIVATE_ORIGIN_URL" "$REPO_DIR" \
  >> "$LOG_FILE" 2>&1; then
  stop_with_evidence "could not clone private origin/main"
fi
ORIGIN_HEAD=$(git -C "$REPO_DIR" rev-parse refs/remotes/origin/main 2>> "$LOG_FILE") \
  || stop_with_evidence "private origin/main is missing"

if ! git -C "$REPO_DIR" remote add "$UPSTREAM_REMOTE" "$PUBLIC_UPSTREAM_URL" \
  >> "$LOG_FILE" 2>&1; then
  stop_with_evidence "could not configure the public upstream in the disposable clone"
fi
git -C "$REPO_DIR" remote set-url --push "$UPSTREAM_REMOTE" "$READ_ONLY_PUSH_URL" \
  >> "$LOG_FILE" 2>&1 \
  || stop_with_evidence "could not disable public upstream pushes in the disposable clone"
if ! git -C "$REPO_DIR" fetch --quiet --no-tags "$UPSTREAM_REMOTE" \
  "+refs/heads/$UPSTREAM_REF:refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_REF" \
  >> "$LOG_FILE" 2>&1; then
  stop_with_evidence "could not fetch $PUBLIC_UPSTREAM"
fi
UPSTREAM_HEAD=$(git -C "$REPO_DIR" rev-parse "refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_REF" \
  2>> "$LOG_FILE") || stop_with_evidence "cannot resolve $PUBLIC_UPSTREAM"

if ! git -C "$REPO_DIR" remote add running-copy "$FM_ROOT" >> "$LOG_FILE" 2>&1; then
  stop_with_evidence "could not inspect running main from the disposable clone"
fi
if ! git -C "$REPO_DIR" fetch --quiet --no-tags running-copy \
  '+refs/heads/main:refs/remotes/running-copy/main' >> "$LOG_FILE" 2>&1; then
  stop_with_evidence "could not read running main from the disposable clone"
fi
RUNNING_HEAD=$(git -C "$REPO_DIR" rev-parse refs/remotes/running-copy/main 2>> "$LOG_FILE") \
  || stop_with_evidence "cannot resolve running main in the disposable clone"
[ "$RUNNING_HEAD" = "$LOCAL_HEAD" ] \
  || stop_with_evidence "running main changed during private update setup"
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$RUNNING_HEAD" "$ORIGIN_HEAD" \
  >> "$LOG_FILE" 2>&1; then
  stop_with_evidence "running main has commits not present on private origin/main"
fi

if git -C "$REPO_DIR" merge-base --is-ancestor "$UPSTREAM_HEAD" "$ORIGIN_HEAD" \
  >> "$LOG_FILE" 2>&1; then
  printf 'private-upstream: already current at %s\n' \
    "$(git -C "$REPO_DIR" rev-parse --short "$ORIGIN_HEAD")"
  remove_success_clone
  exit 0
fi

GIT_NAME=$(git -C "$FM_ROOT" config user.name 2>/dev/null || printf '%s' "${GIT_AUTHOR_NAME:-}")
GIT_EMAIL=$(git -C "$FM_ROOT" config user.email 2>/dev/null || printf '%s' "${GIT_AUTHOR_EMAIL:-}")
[ -n "$GIT_NAME" ] || stop_with_evidence "git user.name is required for upstream integration"
[ -n "$GIT_EMAIL" ] || stop_with_evidence "git user.email is required for upstream integration"
git -C "$REPO_DIR" config user.name "$GIT_NAME" \
  || stop_with_evidence "could not configure integration commit identity"
git -C "$REPO_DIR" config user.email "$GIT_EMAIL" \
  || stop_with_evidence "could not configure integration commit identity"
git -C "$REPO_DIR" config commit.gpgSign false \
  || stop_with_evidence "could not configure non-interactive integration commits"

if ! GIT_MERGE_AUTOEDIT=no git -C "$REPO_DIR" merge --no-edit \
  "refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_REF" >> "$LOG_FILE" 2>&1; then
  git -C "$REPO_DIR" status --short >> "$LOG_FILE" 2>&1 || true
  stop_with_evidence "merge conflict while integrating $PUBLIC_UPSTREAM"
fi
INTEGRATED_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD 2>> "$LOG_FILE") \
  || stop_with_evidence "cannot read the integrated result"

if [ ! -x "$REPO_DIR/bin/fm-lint.sh" ] || [ ! -x "$REPO_DIR/bin/fm-test-run.sh" ]; then
  stop_with_evidence "integrated result is missing executable validation entrypoints"
fi
if ! (cd "$REPO_DIR" && bin/fm-lint.sh) > "$VALIDATION_LOG" 2>&1; then
  stop_with_evidence "lint failed"
fi
if ! (cd "$REPO_DIR" && bin/fm-test-run.sh --all) >> "$VALIDATION_LOG" 2>&1; then
  stop_with_evidence "test suite failed"
fi
if [ -n "$(git -C "$REPO_DIR" status --porcelain 2>> "$VALIDATION_LOG")" ]; then
  stop_with_evidence "validation left the integration clone dirty"
fi
[ "$(git -C "$REPO_DIR" rev-parse HEAD 2>> "$VALIDATION_LOG")" = "$INTEGRATED_HEAD" ] \
  || stop_with_evidence "validation changed the integrated commit"

if ! git -C "$REPO_DIR" push --porcelain "$PRIVATE_ORIGIN_URL" \
  'HEAD:refs/heads/main' > "$PUSH_LOG" 2>&1; then
  stop_with_evidence "push to private origin/main failed"
fi
PUBLISHED_HEAD=$(git ls-remote "$PRIVATE_ORIGIN_URL" refs/heads/main 2>> "$PUSH_LOG" \
  | awk 'NR == 1 { print $1 }')
[ "$PUBLISHED_HEAD" = "$INTEGRATED_HEAD" ] \
  || stop_with_evidence "private origin/main did not verify at the integrated commit"

printf 'private-upstream: published %s..%s from %s\n' \
  "$(git -C "$REPO_DIR" rev-parse --short "$ORIGIN_HEAD")" \
  "$(git -C "$REPO_DIR" rev-parse --short "$INTEGRATED_HEAD")" \
  "$PUBLIC_UPSTREAM"
remove_success_clone
