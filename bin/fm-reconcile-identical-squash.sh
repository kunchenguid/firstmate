#!/usr/bin/env bash
# Explicitly reconcile one clean repository whose checked-out local default
# branch and origin's source-backed default branch genuinely diverged but have
# identical root trees.
#
# The operator must quiesce every other Git claimant before invoking this helper.
# The helper proves the local repository shape, obtains origin's current default
# branch object with a source-only fetch, and atomically creates or verifies a
# deterministic preservation ref while moving only the direct local default
# branch ref. It never changes ordinary fm-fleet-sync.sh behavior.
#
# Source acquisition uses an empty --refmap together with a source-only refspec,
# --no-write-fetch-head, --no-tags, --no-prune, --no-prune-tags, and
# --no-recurse-submodules. This suppresses configured destination refspecs,
# remote-tracking updates, FETCH_HEAD writes, tag following, pruning, and
# submodule recursion. A fixed three-attempt loop tolerates a source tip
# advancing between fetch and source-backed observation.
#
# Preservation refs have this form:
#   refs/firstmate/identical-squash/<hex-encoded-default-branch>/<full-old-oid>
# The branch encoding and complete old object identity make the name
# deterministic. Existing exact direct refs are reused; conflicting or symbolic
# refs are refused. Ref creation/verification and branch movement share one
# `git update-ref --stdin` transaction with per-command `option no-deref` and
# expected-old verification.
#
# A successful second invocation is recognized only when the local branch still
# equals the source-backed remote tip and a valid preservation ref proves a prior
# divergent, single-merge-base, identical-tree reconciliation for that branch.
#
# Git does not provide repository-wide serialization across unrelated commands.
# This helper therefore relies on explicit operator quiescence, checks evidence
# immediately before and after its transaction, and never rolls back after a
# committed transaction. If a new claimant appears after commit, diagnostics
# retain the exact committed target and preserved old head so an operator can
# investigate without overwriting that claimant.
#
# Usage: fm-reconcile-identical-squash.sh <repository-directory>
set -eu

PROGRAM=fm-reconcile-identical-squash
MAX_SOURCE_ATTEMPTS=3
AUTHORITATIVE_REMOTE=origin
TAB=$(printf '\t')
export GIT_OPTIONAL_LOCKS=0
export GIT_TERMINAL_PROMPT=0

usage() {
  printf 'usage: fm-reconcile-identical-squash.sh <repository-directory>\n' >&2
  printf 'requires: quiesce every other Git claimant before invocation\n' >&2
}

refuse() {
  printf '%s: refusing: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

reject_ambient_git_overrides() {
  local name
  for name in \
    GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_CONFIG \
    GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_COUNT \
    GIT_DIR \
    GIT_WORK_TREE \
    GIT_IMPLICIT_WORK_TREE \
    GIT_COMMON_DIR \
    GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY \
    GIT_GRAFT_FILE \
    GIT_SHALLOW_FILE \
    GIT_NO_REPLACE_OBJECTS \
    GIT_REPLACE_REF_BASE \
    GIT_NAMESPACE \
    GIT_QUARANTINE_PATH
  do
    if declare -p "$name" >/dev/null 2>&1; then
      refuse "ambient Git environment override $name must be unset"
    fi
  done
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage; exit 2; }
REPO_ARG=$1
[ -d "$REPO_ARG" ] || refuse "repository directory does not exist"
reject_ambient_git_overrides

if ! inside=$(git -C "$REPO_ARG" rev-parse --is-inside-work-tree 2>/dev/null); then
  refuse "target is not an existing Git worktree"
fi
[ "$inside" = true ] || refuse "target is not an existing Git worktree"
if ! REPO=$(git -C "$REPO_ARG" rev-parse --path-format=absolute --show-toplevel 2>/dev/null); then
  refuse "cannot resolve the repository worktree root"
fi
if ! GIT_DIR=$(git -C "$REPO" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null); then
  refuse "cannot resolve the repository Git directory"
fi
if ! COMMON_DIR=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  refuse "cannot resolve the repository common Git directory"
fi
[ -d "$GIT_DIR" ] || refuse "resolved Git directory is not a directory"
[ -d "$COMMON_DIR" ] || refuse "resolved common Git directory is not a directory"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-reconcile-identical-squash.XXXXXX") \
  || refuse "cannot create private temporary evidence directory"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

repo_git() {
  git -C "$REPO" "$@"
}

history_state_valid() {
  local shallow grafts replacements
  HISTORY_ERROR=
  if ! shallow=$(repo_git rev-parse --is-shallow-repository 2>/dev/null); then
    HISTORY_ERROR="cannot determine whether repository history is shallow"
    return 1
  fi
  case "$shallow" in
    false) ;;
    true)
      HISTORY_ERROR="repository history is shallow"
      return 1
      ;;
    *)
      HISTORY_ERROR="repository shallow-history state is ambiguous"
      return 1
      ;;
  esac
  if ! grafts=$(repo_git rev-parse --path-format=absolute --git-path info/grafts 2>/dev/null); then
    HISTORY_ERROR="cannot resolve the legacy graft path"
    return 1
  fi
  if [ -e "$grafts" ] || [ -L "$grafts" ]; then
    HISTORY_ERROR="legacy graft history is present"
    return 1
  fi
  if ! replacements=$(repo_git for-each-ref --format='%(refname)' refs/replace 2>/dev/null); then
    HISTORY_ERROR="cannot inspect replacement object refs"
    return 1
  fi
  if [ -n "$replacements" ]; then
    HISTORY_ERROR="replacement object history is present"
    return 1
  fi
  return 0
}

require_clean() {
  local status_output
  status_output=$(repo_git status --porcelain=v1 --untracked-files=normal 2>/dev/null) \
    || return 1
  [ -z "$status_output" ]
}

worktree_count() {
  local output count
  output=$(repo_git worktree list --porcelain 2>/dev/null) || return 1
  count=$(printf '%s\n' "$output" | grep -c '^worktree ' || true)
  printf '%s\n' "$count"
}

active_operation_present() {
  local marker path
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_START; do
    path=$(repo_git rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null) \
      || return 0
    [ ! -e "$path" ] || return 0
  done
  for marker in rebase-apply rebase-merge sequencer; do
    path=$(repo_git rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null) \
      || return 0
    [ ! -e "$path" ] || return 0
  done
  for marker in index.lock HEAD.lock FETCH_HEAD.lock packed-refs.lock "$HEAD_REF.lock"; do
    path=$(repo_git rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null) \
      || return 0
    [ ! -e "$path" ] || return 0
  done
  return 1
}

snapshot_refs() {
  local destination=$1
  repo_git for-each-ref --format='%(refname)%09%(objectname)%09%(symref)' \
    > "$destination" 2>/dev/null
}

snapshot_unrelated_refs() {
  local source=$1 destination=$2 ref object symref
  : > "$destination"
  while IFS="$TAB" read -r ref object symref || [ -n "${ref:-}${object:-}${symref:-}" ]; do
    [ -n "${ref:-}" ] || continue
    case "$ref" in
      "$HEAD_REF"|"$PRESERVE_REF") continue ;;
    esac
    printf '%s\t%s\t%s\n' "$ref" "$object" "$symref" >> "$destination"
  done < "$source"
}

snapshot_fetch_head() {
  if [ -L "$FETCH_HEAD_PATH" ]; then
    refuse "FETCH_HEAD is a symbolic link"
  fi
  if [ -e "$FETCH_HEAD_PATH" ]; then
    printf 'present\n' > "$TMP_ROOT/fetch-head.state"
    cp "$FETCH_HEAD_PATH" "$TMP_ROOT/fetch-head.bytes" \
      || refuse "cannot snapshot FETCH_HEAD"
  else
    printf 'absent\n' > "$TMP_ROOT/fetch-head.state"
  fi
}

fetch_head_unchanged() {
  local state
  state=$(cat "$TMP_ROOT/fetch-head.state") || return 1
  case "$state" in
    present)
      [ -f "$FETCH_HEAD_PATH" ] && [ ! -L "$FETCH_HEAD_PATH" ] \
        && cmp -s "$TMP_ROOT/fetch-head.bytes" "$FETCH_HEAD_PATH"
      ;;
    absent)
      [ ! -e "$FETCH_HEAD_PATH" ] && [ ! -L "$FETCH_HEAD_PATH" ]
      ;;
    *) return 1 ;;
  esac
}

observe_remote_default() {
  local output first second extra ref_count=0 oid_count=0 candidate
  OBSERVED_REMOTE_REF=
  OBSERVED_REMOTE_OID=
  if ! output=$(repo_git ls-remote --symref --exit-code \
      "$AUTHORITATIVE_REMOTE" HEAD 2>"$TMP_ROOT/ls-remote.err"); then
    return 1
  fi
  while IFS="$TAB" read -r first second extra || [ -n "${first:-}${second:-}${extra:-}" ]; do
    [ "$second" = HEAD ] || continue
    [ -z "${extra:-}" ] || return 1
    case "$first" in
      'ref: refs/heads/'*)
        candidate=${first#ref: }
        ref_count=$((ref_count + 1))
        OBSERVED_REMOTE_REF=$candidate
        ;;
      *)
        case "$first" in
          ''|*[!0-9a-fA-F]*) return 1 ;;
        esac
        oid_count=$((oid_count + 1))
        OBSERVED_REMOTE_OID=$first
        ;;
    esac
  done <<EOF
$output
EOF
  [ "$ref_count" -eq 1 ] && [ "$oid_count" -eq 1 ] \
    && repo_git check-ref-format "$OBSERVED_REMOTE_REF" >/dev/null 2>&1
}

branch_hex() {
  LC_ALL=C printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

anchor_namespace_valid() {
  local ref object symref suffix resolved output
  ANCHOR_ERROR=
  if ! output=$(repo_git for-each-ref \
      --format='%(refname)%09%(objectname)%09%(symref)' "$PRESERVE_PREFIX" 2>/dev/null); then
    ANCHOR_ERROR="cannot inspect preservation refs"
    return 1
  fi
  while IFS="$TAB" read -r ref object symref || [ -n "${ref:-}${object:-}${symref:-}" ]; do
    [ -n "${ref:-}" ] || continue
    case "$ref" in
      "$PRESERVE_PREFIX"/*) ;;
      *) continue ;;
    esac
    suffix=${ref#"$PRESERVE_PREFIX"/}
    case "$suffix" in
      ''|*/*)
        ANCHOR_ERROR="malformed preservation ref exists for the default branch"
        return 1
        ;;
    esac
    if [ -n "${symref:-}" ] || repo_git symbolic-ref -q "$ref" >/dev/null 2>&1; then
      ANCHOR_ERROR="symbolic preservation ref exists for the default branch"
      return 1
    fi
    [ "$suffix" = "$object" ] || {
      ANCHOR_ERROR="conflicting preservation ref exists for the default branch"
      return 1
    }
    if ! resolved=$(repo_git rev-parse --verify "$object^{commit}" 2>/dev/null); then
      ANCHOR_ERROR="preservation ref does not name a commit"
      return 1
    fi
    [ "$resolved" = "$object" ] || {
      ANCHOR_ERROR="preservation ref does not directly name its bound commit"
      return 1
    }
  done <<EOF
$output
EOF
  return 0
}

merge_base_count() {
  local left=$1 right=$2 output rc count
  set +e
  output=$(repo_git merge-base --all "$left" "$right" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ -z "$output" ]; then
    printf '0\n'
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  count=$(printf '%s\n' "$output" | awk 'NF { n++ } END { print n + 0 }')
  printf '%s\n' "$count"
}

find_idempotent_anchor() {
  local current_oid=$1 current_tree=$2 output ref object symref anchor_tree bases
  IDEMPOTENT_REF=
  if ! output=$(repo_git for-each-ref \
      --format='%(refname)%09%(objectname)%09%(symref)' "$PRESERVE_PREFIX" 2>/dev/null); then
    return 1
  fi
  while IFS="$TAB" read -r ref object symref || [ -n "${ref:-}${object:-}${symref:-}" ]; do
    case "${ref:-}" in
      "$PRESERVE_PREFIX"/*) ;;
      *) continue ;;
    esac
    [ -z "${symref:-}" ] || return 1
    anchor_tree=$(repo_git rev-parse --verify "$object^{tree}" 2>/dev/null) || return 1
    [ "$anchor_tree" = "$current_tree" ] || continue
    if repo_git merge-base --is-ancestor "$object" "$current_oid" 2>/dev/null; then
      continue
    fi
    if repo_git merge-base --is-ancestor "$current_oid" "$object" 2>/dev/null; then
      continue
    fi
    bases=$(merge_base_count "$object" "$current_oid") || return 1
    [ "$bases" -eq 1 ] || continue
    if [ -z "$IDEMPOTENT_REF" ] || [ "$ref" \< "$IDEMPOTENT_REF" ]; then
      IDEMPOTENT_REF=$ref
    fi
  done <<EOF
$output
EOF
  [ -n "$IDEMPOTENT_REF" ]
}

post_commit_fail() {
  local detail=$1 claimant
  claimant=$(repo_git rev-parse --verify "$HEAD_REF" 2>/dev/null || printf 'unresolved')
  printf '%s: post-commit evidence changed: %s\n' "$PROGRAM" "$detail" >&2
  printf '%s: committed outcome: %s moved from %s to %s; preserved old head at %s; current branch ref is %s; no rollback was attempted\n' \
    "$PROGRAM" "$HEAD_REF" "$LOCAL_OID" "$REMOTE_OID" "$PRESERVE_REF" "$claimant" >&2
  exit 1
}

history_state_valid || refuse "$HISTORY_ERROR"
if ! HEAD_REF=$(repo_git symbolic-ref --no-recurse -q HEAD 2>/dev/null); then
  refuse "HEAD is detached"
fi
case "$HEAD_REF" in
  refs/heads/*) ;;
  *) refuse "HEAD is not attached to a local branch" ;;
esac
DEFAULT_BRANCH=${HEAD_REF#refs/heads/}
repo_git check-ref-format --branch "$DEFAULT_BRANCH" >/dev/null 2>&1 \
  || refuse "checked-out branch name is unsupported"
if repo_git symbolic-ref -q "$HEAD_REF" >/dev/null 2>&1; then
  refuse "checked-out local branch ref is symbolic"
fi
if ! LOCAL_RAW=$(repo_git rev-parse --verify "$HEAD_REF" 2>/dev/null); then
  refuse "cannot resolve the checked-out local branch ref"
fi
if ! LOCAL_OID=$(repo_git rev-parse --verify "$HEAD_REF^{commit}" 2>/dev/null); then
  refuse "checked-out local branch does not name a commit"
fi
[ "$LOCAL_RAW" = "$LOCAL_OID" ] \
  || refuse "checked-out local branch does not directly name a commit"
HEAD_OID=$(repo_git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || refuse "cannot resolve current HEAD"
[ "$HEAD_OID" = "$LOCAL_OID" ] \
  || refuse "HEAD and the checked-out local branch disagree"
require_clean || refuse "worktree or index is not clean"
COUNT=$(worktree_count) || refuse "cannot enumerate repository worktrees"
[ "$COUNT" -eq 1 ] || refuse "repository has $COUNT registered worktrees; exactly one is required"
active_operation_present && refuse "an active Git operation or lock is present"
repo_git remote get-url "$AUTHORITATIVE_REMOTE" >/dev/null 2>&1 \
  || refuse "authoritative origin remote is missing"

observe_remote_default \
  || refuse "cannot confidently resolve origin's source-backed default branch"
REMOTE_REF=$OBSERVED_REMOTE_REF
[ "$REMOTE_REF" = "refs/heads/$DEFAULT_BRANCH" ] \
  || refuse "checked-out branch is not origin's source-backed default branch"
REMOTE_TRACKING_REF="refs/remotes/$AUTHORITATIVE_REMOTE/$DEFAULT_BRANCH"
if repo_git symbolic-ref -q "$REMOTE_TRACKING_REF" >/dev/null 2>&1; then
  refuse "observed remote-tracking default ref is symbolic"
fi

BRANCH_HEX=$(branch_hex "$DEFAULT_BRANCH")
[ -n "$BRANCH_HEX" ] || refuse "cannot encode the default branch name"
PRESERVE_PREFIX="refs/firstmate/identical-squash/$BRANCH_HEX"
PRESERVE_REF="$PRESERVE_PREFIX/$LOCAL_OID"
repo_git check-ref-format "$PRESERVE_REF" >/dev/null 2>&1 \
  || refuse "deterministic preservation ref name is invalid"
anchor_namespace_valid || refuse "$ANCHOR_ERROR"
PRESERVE_MODE=create
if repo_git symbolic-ref -q "$PRESERVE_REF" >/dev/null 2>&1; then
  refuse "deterministic preservation ref is symbolic"
elif repo_git show-ref --verify --quiet "$PRESERVE_REF"; then
  EXISTING_PRESERVE=$(repo_git rev-parse --verify "$PRESERVE_REF" 2>/dev/null) \
    || refuse "cannot resolve existing preservation ref"
  [ "$EXISTING_PRESERVE" = "$LOCAL_OID" ] \
    || refuse "deterministic preservation ref conflicts with the old local commit"
  PRESERVE_MODE=verify
fi

FETCH_HEAD_PATH=$(repo_git rev-parse --path-format=absolute --git-path FETCH_HEAD 2>/dev/null) \
  || refuse "cannot resolve FETCH_HEAD"
snapshot_fetch_head
snapshot_refs "$TMP_ROOT/refs.initial" || refuse "cannot snapshot repository refs"

attempt=1
REMOTE_OID=
REMOTE_TREE=
while [ "$attempt" -le "$MAX_SOURCE_ATTEMPTS" ]; do
  if ! repo_git fetch --quiet --no-write-fetch-head --no-tags --no-prune \
      --no-prune-tags --no-recurse-submodules --refmap= \
      "$AUTHORITATIVE_REMOTE" "$REMOTE_REF" \
      >"$TMP_ROOT/fetch.out" 2>"$TMP_ROOT/fetch.err"; then
    refuse "source-only fetch from origin failed; inspect remote access without exposing credentials"
  fi
  snapshot_refs "$TMP_ROOT/refs.after-fetch" \
    || refuse "cannot verify refs after source-only fetch"
  cmp -s "$TMP_ROOT/refs.initial" "$TMP_ROOT/refs.after-fetch" \
    || refuse "source acquisition changed a repository ref"
  fetch_head_unchanged || refuse "source acquisition changed FETCH_HEAD"
  history_state_valid || refuse "$HISTORY_ERROR"

  observe_remote_default \
    || refuse "cannot observe origin's default branch after source-only fetch"
  [ "$OBSERVED_REMOTE_REF" = "$REMOTE_REF" ] \
    || refuse "origin's default branch identity changed during reconciliation"
  candidate=$OBSERVED_REMOTE_OID
  if ! resolved_candidate=$(repo_git rev-parse --verify "$candidate^{commit}" 2>/dev/null); then
    if [ "$attempt" -lt "$MAX_SOURCE_ATTEMPTS" ]; then
      attempt=$((attempt + 1))
      continue
    fi
    refuse "origin's default tip advanced beyond the fetched object in $MAX_SOURCE_ATTEMPTS attempts"
  fi
  if [ "$resolved_candidate" != "$candidate" ]; then
    refuse "origin's default branch does not directly name a commit"
  fi

  if [ "$LOCAL_OID" = "$candidate" ]; then
    candidate_tree=$(repo_git rev-parse --verify "$candidate^{tree}" 2>/dev/null) \
      || refuse "cannot resolve the current root tree"
  else
    if repo_git merge-base --is-ancestor "$LOCAL_OID" "$candidate" 2>/dev/null; then
      refuse "local default branch is only behind origin; use an ordinary fast-forward"
    fi
    if repo_git merge-base --is-ancestor "$candidate" "$LOCAL_OID" 2>/dev/null; then
      refuse "local default branch is ahead of origin"
    fi
    BASE_COUNT=$(merge_base_count "$LOCAL_OID" "$candidate") \
      || refuse "cannot determine the merge-base set"
    [ "$BASE_COUNT" -gt 0 ] || refuse "local and origin histories are unrelated"
    [ "$BASE_COUNT" -eq 1 ] || refuse "local and origin histories have an ambiguous merge-base set"
    LOCAL_TREE=$(repo_git rev-parse --verify "$LOCAL_OID^{tree}" 2>/dev/null) \
      || refuse "cannot resolve the local root tree"
    candidate_tree=$(repo_git rev-parse --verify "$candidate^{tree}" 2>/dev/null) \
      || refuse "cannot resolve origin's root tree"
    [ "$LOCAL_TREE" = "$candidate_tree" ] \
      || refuse "local and origin root trees are not identical"
  fi

  observe_remote_default \
    || refuse "cannot re-observe origin immediately before reconciliation"
  [ "$OBSERVED_REMOTE_REF" = "$REMOTE_REF" ] \
    || refuse "origin's default branch identity changed during reconciliation"
  if [ "$OBSERVED_REMOTE_OID" != "$candidate" ]; then
    if [ "$attempt" -lt "$MAX_SOURCE_ATTEMPTS" ]; then
      attempt=$((attempt + 1))
      continue
    fi
    refuse "origin's default tip did not stabilize in $MAX_SOURCE_ATTEMPTS attempts"
  fi
  REMOTE_OID=$candidate
  REMOTE_TREE=$candidate_tree
  break
done
[ -n "$REMOTE_OID" ] || refuse "could not obtain a stable source-backed origin tip"

if [ "$LOCAL_OID" = "$REMOTE_OID" ]; then
  history_state_valid || refuse "$HISTORY_ERROR"
  anchor_namespace_valid || refuse "$ANCHOR_ERROR"
  find_idempotent_anchor "$LOCAL_OID" "$REMOTE_TREE" \
    || refuse "local default branch already equals origin without valid prior reconciliation evidence"
  snapshot_refs "$TMP_ROOT/refs.idempotent" \
    || refuse "cannot verify refs for repeat-run convergence"
  cmp -s "$TMP_ROOT/refs.initial" "$TMP_ROOT/refs.idempotent" \
    || refuse "repository refs changed during repeat-run verification"
  fetch_head_unchanged || refuse "FETCH_HEAD changed during repeat-run verification"
  require_clean || refuse "worktree or index changed during repeat-run verification"
  COUNT=$(worktree_count) || refuse "cannot re-enumerate repository worktrees"
  [ "$COUNT" -eq 1 ] || refuse "repository worktree count changed during repeat-run verification"
  active_operation_present && refuse "an active Git operation appeared during repeat-run verification"
  printf '%s: already reconciled: %s is at source-backed origin commit %s; preserved prior head evidence at %s\n' \
    "$PROGRAM" "$HEAD_REF" "$REMOTE_OID" "$IDEMPOTENT_REF"
  exit 0
fi

# Re-prove every local precondition immediately before the sole ref mutation.
CURRENT_HEAD_REF=$(repo_git symbolic-ref --no-recurse -q HEAD 2>/dev/null) \
  || refuse "HEAD detached before the atomic ref transaction"
[ "$CURRENT_HEAD_REF" = "$HEAD_REF" ] \
  || refuse "checked-out branch changed before the atomic ref transaction"
repo_git symbolic-ref -q "$HEAD_REF" >/dev/null 2>&1 \
  && refuse "local default branch became symbolic before the atomic ref transaction"
CURRENT_LOCAL=$(repo_git rev-parse --verify "$HEAD_REF" 2>/dev/null) \
  || refuse "cannot re-read the local default branch"
[ "$CURRENT_LOCAL" = "$LOCAL_OID" ] \
  || refuse "local default branch changed before the atomic ref transaction"
require_clean || refuse "worktree or index changed before the atomic ref transaction"
COUNT=$(worktree_count) || refuse "cannot re-enumerate repository worktrees"
[ "$COUNT" -eq 1 ] || refuse "repository worktree count changed before the atomic ref transaction"
active_operation_present && refuse "an active Git operation appeared before the atomic ref transaction"
history_state_valid || refuse "$HISTORY_ERROR"
anchor_namespace_valid || refuse "$ANCHOR_ERROR"
if [ "$PRESERVE_MODE" = create ]; then
  repo_git show-ref --verify --quiet "$PRESERVE_REF" \
    && refuse "deterministic preservation ref appeared before the atomic ref transaction"
  repo_git symbolic-ref -q "$PRESERVE_REF" >/dev/null 2>&1 \
    && refuse "deterministic preservation ref became symbolic before the atomic ref transaction"
else
  repo_git symbolic-ref -q "$PRESERVE_REF" >/dev/null 2>&1 \
    && refuse "deterministic preservation ref became symbolic before the atomic ref transaction"
  CURRENT_PRESERVE=$(repo_git rev-parse --verify "$PRESERVE_REF" 2>/dev/null) \
    || refuse "existing preservation ref disappeared before the atomic ref transaction"
  [ "$CURRENT_PRESERVE" = "$LOCAL_OID" ] \
    || refuse "existing preservation ref changed before the atomic ref transaction"
fi
snapshot_refs "$TMP_ROOT/refs.pre-transaction" \
  || refuse "cannot verify refs before the atomic ref transaction"
cmp -s "$TMP_ROOT/refs.initial" "$TMP_ROOT/refs.pre-transaction" \
  || refuse "a repository ref changed before the atomic ref transaction"
fetch_head_unchanged || refuse "FETCH_HEAD changed before the atomic ref transaction"
observe_remote_default \
  || refuse "cannot observe origin at the atomic transaction boundary"
[ "$OBSERVED_REMOTE_REF" = "$REMOTE_REF" ] && [ "$OBSERVED_REMOTE_OID" = "$REMOTE_OID" ] \
  || refuse "origin changed at the atomic transaction boundary; rerun after quiescing writers"

{
  printf 'start\n'
  if [ "$PRESERVE_MODE" = create ]; then
    printf 'option no-deref\n'
    printf 'create %s %s\n' "$PRESERVE_REF" "$LOCAL_OID"
  else
    printf 'option no-deref\n'
    printf 'update %s %s %s\n' "$PRESERVE_REF" "$LOCAL_OID" "$LOCAL_OID"
  fi
  printf 'option no-deref\n'
  printf 'update %s %s %s\n' "$HEAD_REF" "$REMOTE_OID" "$LOCAL_OID"
  printf 'prepare\n'
  printf 'commit\n'
} > "$TMP_ROOT/update-ref.stdin"

if ! repo_git update-ref --stdin < "$TMP_ROOT/update-ref.stdin" \
    >"$TMP_ROOT/update-ref.out" 2>"$TMP_ROOT/update-ref.err"; then
  refuse "atomic ref transaction was rejected, likely because a concurrent claimant changed evidence; no reconciliation transaction was committed"
fi
printf '%s: committed: moved %s from %s to %s; preserved old head at %s\n' \
  "$PROGRAM" "$HEAD_REF" "$LOCAL_OID" "$REMOTE_OID" "$PRESERVE_REF"

# Never roll back below this line. A new claimant owns any post-commit change.
CURRENT_HEAD_REF=$(repo_git symbolic-ref --no-recurse -q HEAD 2>/dev/null) \
  || post_commit_fail "HEAD detached after the transaction"
[ "$CURRENT_HEAD_REF" = "$HEAD_REF" ] \
  || post_commit_fail "checked-out branch identity changed after the transaction"
repo_git symbolic-ref -q "$HEAD_REF" >/dev/null 2>&1 \
  && post_commit_fail "local default branch became symbolic after the transaction"
CURRENT_LOCAL=$(repo_git rev-parse --verify "$HEAD_REF" 2>/dev/null) \
  || post_commit_fail "local default branch became unreadable after the transaction"
[ "$CURRENT_LOCAL" = "$REMOTE_OID" ] \
  || post_commit_fail "local default branch no longer names the committed remote target"
CURRENT_HEAD=$(repo_git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || post_commit_fail "HEAD became unreadable after the transaction"
[ "$CURRENT_HEAD" = "$REMOTE_OID" ] \
  || post_commit_fail "HEAD no longer names the committed remote target"
require_clean || post_commit_fail "worktree or index changed after the transaction"
COUNT=$(worktree_count) || post_commit_fail "repository worktrees became unreadable after the transaction"
[ "$COUNT" -eq 1 ] || post_commit_fail "repository worktree count changed after the transaction"
active_operation_present && post_commit_fail "an active Git operation appeared after the transaction"
repo_git symbolic-ref -q "$PRESERVE_REF" >/dev/null 2>&1 \
  && post_commit_fail "preservation ref became symbolic after the transaction"
CURRENT_PRESERVE=$(repo_git rev-parse --verify "$PRESERVE_REF" 2>/dev/null) \
  || post_commit_fail "preservation ref became unreadable after the transaction"
[ "$CURRENT_PRESERVE" = "$LOCAL_OID" ] \
  || post_commit_fail "preservation ref no longer names the old local head"
history_state_valid || post_commit_fail "$HISTORY_ERROR"
CURRENT_TREE=$(repo_git rev-parse --verify "$REMOTE_OID^{tree}" 2>/dev/null) \
  || post_commit_fail "committed remote root tree became unreadable"
[ "$CURRENT_TREE" = "$REMOTE_TREE" ] \
  || post_commit_fail "committed remote root tree identity changed"
fetch_head_unchanged || post_commit_fail "FETCH_HEAD changed after the transaction"
snapshot_refs "$TMP_ROOT/refs.post-transaction" \
  || post_commit_fail "repository refs became unreadable after the transaction"
snapshot_unrelated_refs "$TMP_ROOT/refs.initial" "$TMP_ROOT/refs.initial-unrelated"
snapshot_unrelated_refs "$TMP_ROOT/refs.post-transaction" "$TMP_ROOT/refs.post-unrelated"
cmp -s "$TMP_ROOT/refs.initial-unrelated" "$TMP_ROOT/refs.post-unrelated" \
  || post_commit_fail "an unrelated repository ref changed after the transaction"
observe_remote_default \
  || post_commit_fail "origin could not be observed after the transaction"
[ "$OBSERVED_REMOTE_REF" = "$REMOTE_REF" ] && [ "$OBSERVED_REMOTE_OID" = "$REMOTE_OID" ] \
  || post_commit_fail "origin's source-backed default branch changed after the transaction"
anchor_namespace_valid || post_commit_fail "$ANCHOR_ERROR"
find_idempotent_anchor "$REMOTE_OID" "$REMOTE_TREE" \
  || post_commit_fail "repeat-run convergence evidence is incomplete"

printf '%s: verified: HEAD and %s are clean at %s; prior head %s remains at %s; a repeat invocation will converge without mutation\n' \
  "$PROGRAM" "$HEAD_REF" "$REMOTE_OID" "$LOCAL_OID" "$PRESERVE_REF"
