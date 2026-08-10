#!/usr/bin/env bash
# Single owner of a task's TWO base references. A dispatched worker needs two
# different commits and the previous spawn path supplied only one, so a brief
# citing a file or a line number is silently unreliable whenever they differ:
#
#   slot base           the commit the task's worktree is placed at, so reads,
#                       greps, line citations and running the code all resolve
#                       against what the fleet ACTUALLY RUNS. This is the local
#                       default-branch tip of the project checkout - the same
#                       local-HEAD target secondmates already sync to, and no
#                       fetch is involved.
#   contribution target the commit the task's branch is CUT FROM, so the PR
#                       carries only the task's own commits. On a fork setup
#                       that is the upstream trunk, which is NOT the slot base.
#
# Cutting the branch from the slot base instead is the pollution this file
# exists to prevent: it silently carries every fleet-only commit into the
# contribution. Resetting the slot to the contribution target instead dispatches
# the task onto a trunk missing the code it edits. Neither single ref satisfies
# both roles, so both are resolved, recorded, and stated separately.
#
# Sourced by bin/fm-spawn.sh (resolves and records them) and bin/fm-brief.sh
# (states them to the worker). Depends on bin/fm-ff-lib.sh for default_branch
# and primary_head_commit, and on bin/fm-landed-lib.sh for the
# fetch-url-versus-push-url comparison both libraries reason about and for the
# name of the ref that holds the fork trunk when the local branch lags.
#
# task_base_resolve <repo-dir> sets, and clears first:
#   TASK_BASE_SLOT          slot base commit SHA
#   TASK_BASE_SLOT_REF      the ref it was read from
#   TASK_BASE_CONTRIB       contribution target commit SHA (empty when unresolved)
#   TASK_BASE_CONTRIB_REF   the ref it was read from (or the one that failed)
#   TASK_BASE_STATE         coincident | distinct | unresolved
#   TASK_BASE_ERROR         human-readable reason when resolution degraded
#
# TASK_BASE_STATE is the whole contract in one word:
#   coincident  no distinct upstream, or upstream is already the slot base.
#               The two roles collapse to one commit and nothing changes.
#   distinct    the two differ. The worker MUST be told: read at the slot base,
#               cut its branch at the contribution target.
#   unresolved  an upstream relationship exists but its trunk cannot be read
#               locally. Refused rather than guessed, because silently falling
#               back to the slot base is exactly the pollution above.
#
# THE VENUE IS THE THIRD PROPERTY OF THE SAME CONTRACT
# A contribution target names a commit; it also, implicitly, names the repository
# that commit's trunk belongs to. That repository is where the task's pull
# request has to be raised, and it is NOT a per-project constant on a fork
# layout: a task cut from the upstream trunk belongs upstream, and a task cut
# from the fork trunk belongs at the fork. Deriving it from the target rather
# than from a fixed per-project setting is what makes the venue follow the task.
#
# task_base_venue derives it, and derives it from the target VALUE rather than
# from TASK_BASE_STATE, because the target can be overridden after resolution -
# retargeting a task onto fork-only material is exactly that override, and the
# venue has to move with it.

# shellcheck disable=SC2034 # The resolution outputs are read by callers (fm-spawn.sh) and tests, not by this lib.
TASK_BASE_SLOT='' TASK_BASE_SLOT_REF='' TASK_BASE_CONTRIB='' TASK_BASE_CONTRIB_REF='' TASK_BASE_STATE='' TASK_BASE_ERROR=''
# shellcheck disable=SC2034 # Same: consumed by fm-spawn.sh (records them) and tests.
TASK_BASE_VENUE='' TASK_BASE_VENUE_URL=''

# shellcheck source=bin/fm-landed-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-landed-lib.sh"

# Name the remote-tracking ref that holds the UPSTREAM trunk, when this repo
# contributes somewhere other than where it pushes. Two shapes are recognized:
#   1. a separate `upstream` remote (the conventional fork layout), and
#   2. an `origin` whose fetch URL differs from its push URL, which is the
#      layout firstmate itself uses - origin FETCHES upstream and PUSHES the
#      fork, so `origin/<default>` is the upstream trunk while local
#      `<default>` is the fork trunk.
# The fetch/push comparison in shape 2 is bin/fm-landed-lib.sh's
# fm_landed_push_url, so the two libraries that care about that split read it
# the same way: this one names the upstream side, that one the landing side.
# Prints the ref name, or returns 1 when no distinct upstream exists.
task_base_upstream_ref() {  # <repo-dir>
  local dir=$1 default
  if git -C "$dir" remote get-url upstream >/dev/null 2>&1; then
    default=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/upstream/HEAD 2>/dev/null) \
      && { printf '%s\n' "$default"; return 0; }
    default=$(default_branch "$dir") || return 1
    printf 'upstream/%s\n' "$default"
    return 0
  fi
  fm_landed_push_url "$dir" >/dev/null || return 1
  default=$(default_branch "$dir") || return 1
  printf 'origin/%s\n' "$default"
}

task_base_resolve() {  # <repo-dir>
  local dir=$1 upstream_ref upstream_sha
  TASK_BASE_SLOT=
  TASK_BASE_SLOT_REF=
  TASK_BASE_CONTRIB=
  TASK_BASE_CONTRIB_REF=
  TASK_BASE_STATE=
  TASK_BASE_ERROR=

  TASK_BASE_SLOT_REF=$(default_branch "$dir" 2>/dev/null) || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="no default branch in $dir"
    return 1
  }
  TASK_BASE_SLOT=$(primary_head_commit "$dir") || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="default branch $TASK_BASE_SLOT_REF has no commit in $dir"
    return 1
  }

  # No distinct upstream: the two roles collapse onto the slot base and every
  # caller stays on today's single-reference behavior.
  if ! upstream_ref=$(task_base_upstream_ref "$dir"); then
    TASK_BASE_CONTRIB=$TASK_BASE_SLOT
    TASK_BASE_CONTRIB_REF=$TASK_BASE_SLOT_REF
    TASK_BASE_STATE=coincident
    return 0
  fi

  TASK_BASE_CONTRIB_REF=$upstream_ref
  if ! upstream_sha=$(git -C "$dir" rev-parse --verify --quiet "$upstream_ref^{commit}" 2>/dev/null); then
    # Refuse to guess. Falling back to the slot base here would cut the branch
    # at the fork trunk and carry every fleet-only commit into the PR.
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="upstream trunk $upstream_ref is not readable locally (never fetched?)"
    return 0
  fi
  TASK_BASE_CONTRIB=$upstream_sha
  if [ "$upstream_sha" = "$TASK_BASE_SLOT" ]; then
    TASK_BASE_STATE=coincident
  else
    TASK_BASE_STATE=distinct
  fi
  return 0
}

# The pollution guard. A branch cut from the contribution target descends from
# it, so the target is an ancestor of the branch head and `target..branch` holds
# only the task's own commits. A branch cut from the slot base instead does NOT
# descend from a diverged upstream target, and this fails - which is the whole
# point: it catches the polluted branch whether or not the worker has committed
# anything on top yet.
# Returns 0 clean, 1 polluted, 2 when a ref cannot be read.
task_base_verify_branch() {  # <repo-dir> <contribution-target> <branch-ref>
  local dir=$1 target=$2 branch=$3 target_sha branch_sha
  TASK_BASE_ERROR=
  target_sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="contribution target '$target' is not a readable commit"
    return 2
  }
  branch_sha=$(git -C "$dir" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="branch '$branch' is not a readable commit"
    return 2
  }
  if git -C "$dir" merge-base --is-ancestor "$target_sha" "$branch_sha"; then
    return 0
  fi
  local extra
  extra=$(git -C "$dir" rev-list --count "$target_sha..$branch_sha" 2>/dev/null || echo '?')
  TASK_BASE_ERROR="branch '$branch' does not descend from contribution target '$target'; it carries $extra commit(s) absent from that target, so a PR from it would contribute work the target never had"
  return 1
}

# A remote URL reduced to the forge identity "host/owner/repo", so a recorded
# venue can be compared against a pull request URL without either side keeping a
# second URL parser. Deliberately NOT a general URL parser: it recognizes the
# transports git uses to address a forge and refuses everything else, because a
# venue this cannot name is a venue no guard may claim to have checked.
# Lowercased, since forge hosts and GitHub/GitLab paths are case-insensitive and
# a case difference must never read as a different venue.
# Prints the identity, or returns 1 when the URL names no forge (a local path, a
# file: URL, or any shape without a host and a path).
task_base_venue_identity() {  # <url>
  local url=${1-} rest host path
  case $url in
    '' | /* | file://*) return 1 ;;
  esac
  case $url in
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac

  case $url in
    https://* | http://* | ssh://* | git://*)
      rest=${url#*://}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 1
      host=${host##*@}
      # A port is addressing, not identity, so two URLs differing only by port
      # are the same venue. A bracketed IPv6 literal keeps its brackets.
      case $host in
        '['*']':*) host=${host%:*} ;;
        '['*']') ;;
        *:*) host=${host%%:*} ;;
      esac
      ;;
    *:*)
      # scp-like [user@]host:path, which has no scheme to strip.
      rest=${url##*@}
      host=${rest%%:*}
      path=${rest#*:}
      case $host in
        *'/'*) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac

  path=${path%/}
  path=${path%.git}
  path=${path#/}
  [ -n "$host" ] && [ -n "$path" ] || return 1
  printf '%s/%s\n' "$host" "$path" | tr '[:upper:]' '[:lower:]'
}

# The venue a contribution target names, set into TASK_BASE_VENUE_URL (the
# remote URL) and TASK_BASE_VENUE (its comparable forge identity, empty when the
# URL names no forge).
#
# Both trunks are named by the SAME two-shape upstream resolution
# task_base_upstream_ref performs, so every layout that has a distinct upstream
# derives a venue from it: a separate `upstream` remote names the upstream side
# directly and leaves origin as the fork, and an origin with a fetch/push split
# fetches the upstream side and pushes the fork. Recognizing only the second
# shape would record the fork venue for an upstream-cut task and refuse its
# correct pull request.
#
# The ordering below is the safety property, not a preference. Upstream is
# tested FIRST, so a target the upstream trunk already reaches resolves upstream
# and a target it does not reach can never resolve there. Fork-only commits are
# by definition unreachable from the upstream trunk, so no fork-only target can
# be assigned the upstream venue - which is the inversion that turns a five
# commit contribution into a thirty two commit one.
#
# The fork trunk is then tested against every ref that can hold it, because the
# local branch is the fork trunk only while something keeps fast-forwarding it.
# bin/fm-landed-lib.sh maintains refs/fm-landing/origin/<name> for exactly that
# lag, so a target already on the fork trunk at the forge resolves the fork
# venue instead of degrading to unresolved and leaving its request unchecked.
#
# 0 with the venue set, 2 when it could not be derived. There is no "probably";
# an underivable venue is reported so a caller can refuse rather than guess.
task_base_venue() {  # <repo-dir> <contribution-target>
  local dir=$1 target=${2-} fetch_url push_url upstream_url upstream_ref name target_sha ref landing_ref
  local -a fork_refs
  TASK_BASE_VENUE=
  TASK_BASE_VENUE_URL=
  TASK_BASE_ERROR=

  target_sha=$(git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="contribution target '$target' is not a readable commit"
    return 2
  }
  fetch_url=$(git --no-optional-locks -C "$dir" remote get-url origin 2>/dev/null) || {
    TASK_BASE_ERROR="no origin remote in $dir, so no venue can be named"
    return 2
  }

  # No distinct upstream: the project has one venue and every target names it.
  if ! upstream_ref=$(task_base_upstream_ref "$dir"); then
    TASK_BASE_VENUE_URL=$fetch_url
    TASK_BASE_VENUE=$(task_base_venue_identity "$fetch_url" || true)
    return 0
  fi

  # Which url is which follows the shape task_base_upstream_ref just resolved: a
  # separate `upstream` remote names the upstream side, and otherwise origin
  # FETCHES the upstream side and PUSHES the fork.
  upstream_url=$(git --no-optional-locks -C "$dir" remote get-url upstream 2>/dev/null) || upstream_url=$fetch_url
  push_url=$(fm_landed_push_url "$dir") || push_url=$fetch_url

  if git --no-optional-locks -C "$dir" merge-base --is-ancestor \
    "$target_sha" "$upstream_ref" 2>/dev/null; then
    TASK_BASE_VENUE_URL=$upstream_url
    TASK_BASE_VENUE=$(task_base_venue_identity "$upstream_url" || true)
    return 0
  fi

  name=$(default_branch "$dir" 2>/dev/null) || {
    TASK_BASE_ERROR="no default branch in $dir, so the fork trunk cannot be named"
    return 2
  }
  fork_refs=("refs/heads/$name" "refs/remotes/origin/$name")
  if landing_ref=$(fm_landed_push_target_ref "$dir" "$name"); then
    fork_refs+=("$landing_ref")
  fi
  for ref in "${fork_refs[@]}"; do
    if git --no-optional-locks -C "$dir" merge-base --is-ancestor \
      "$target_sha" "$ref" 2>/dev/null; then
      TASK_BASE_VENUE_URL=$push_url
      TASK_BASE_VENUE=$(task_base_venue_identity "$push_url" || true)
      return 0
    fi
  done

  TASK_BASE_ERROR="contribution target '$target' is on neither the upstream trunk ($upstream_ref) nor the fork trunk ($name), so the venue it names cannot be derived"
  return 2
}
