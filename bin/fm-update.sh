#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates through the configured
# origin.
#
# This is the deterministic owner of /updatefirstmate's update sequence:
#   1. preflight the running checkout before any remote mutation;
#   2. identify origin and any configured upstream without assuming GitHub;
#   3. when origin is a github.com fork, call GitHub's guarded merge-upstream
#      endpoint through gh after validating its API-reported parent (never
#      --force);
#   4. fast-forward the running checkout and every registered secondmate through
#      the existing guarded origin paths; and
#   5. run the existing inherited-local-material convergence after tracked code
#      has converged, so both ends use the updated allowlist and transport.
#
# Local homes are treehouse worktrees or standalone clones. Remote routes update
# their configured code root on that host and then fast-forward the persistent
# home to that root. Every git advance remains FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, create a merge commit, or stash. A tracked-files
# fast-forward never touches gitignored operational directories. Worktrees of
# this repo share one object store, so a single fetch refreshes them all.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or send the tracked-update nudge itself. Those
# are agent and runtime actions the skill performs from this parseable summary:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# GitHub Enterprise origins are treated as non-GitHub direct origins because a
# hostname alone cannot prove that a server implements GitHub's guarded sync
# API. github.com fork metadata and sync failures are fatal. Non-GitHub and local
# origins retain the ordinary direct fast-forward behavior.
# A fork default branch may intentionally carry downstream commits. If its
# parent later advances independently, the histories have unresolved divergence
# and this updater refuses before local, secondmate, or config mutation. A
# separate reviewed upstream-integration branch/PR owns that reconciliation;
# this updater never creates, pushes, or merges one.
#
# Test-only override:
#   FM_CONFIG_PUSH_OVERRIDE=<executable>  replace the config convergence owner.
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
CONFIG_PUSH="${FM_CONFIG_PUSH_OVERRIDE:-$SCRIPT_DIR/fm-config-push.sh}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  cat >&2 <<'EOF'
Usage: fm-update.sh [--help]

Safely update the active Firstmate home through its configured origin.

The updater preflights the local default-branch checkout, identifies origin and
upstream, guardedly synchronizes a github.com fork through gh when applicable,
fast-forwards the local checkout and every registered secondmate, and then runs
inherited-config convergence.

Every git advance is fast-forward only. Dirty work, divergence, authentication
failure, unsupported fork topology, fetch failure, secondmate refusal, or config
convergence failure returns nonzero without forcing, stashing, or merging.

When a downstream fork and its parent have independently advanced, this updater
refuses the unresolved divergence before local or config mutation. Import the
parent through a separate reviewed upstream-integration branch/PR, land it on
the fork default branch, then rerun this command. This updater never creates,
pushes, or merges that integration.

Test-only environment:
  FM_CONFIG_PUSH_OVERRIDE  executable replacing bin/fm-config-push.sh
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

remote_identity() {
  local url=$1 identity
  case "$url" in
    file://*) printf 'local:%s\n' "${url#file://}"; return 0 ;;
    *://*)
      identity=${url#*://}
      identity=${identity#*@}
      ;;
    *@*:*)
      identity=${url#*@}
      identity=${identity/:/\/}
      ;;
    /*|./*|../*) printf 'local:%s\n' "$url"; return 0 ;;
    *) identity=$url ;;
  esac
  identity=${identity%/}
  identity=${identity%.git}
  printf '%s\n' "$identity"
}

github_slug_from_url() {
  local url=$1 lower path
  lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    https://github.com/*|http://github.com/*|ssh://git@github.com/*|\
    https://*@github.com/*|http://*@github.com/*)
      path=${url#*://}
      path=${path#*/}
      ;;
    git@github.com:*)
      path=${url#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  case "$path" in
    */*) ;;
    *) return 1 ;;
  esac
  [ -n "${path%%/*}" ] || return 1
  [ -n "${path#*/}" ] || return 1
  case "${path#*/}" in */*) return 1 ;; esac
  printf '%s\n' "$path"
}

github_repo_identity_is_valid() {
  local identity=$1 owner repo
  case "$identity" in
    */*) ;;
    *) return 1 ;;
  esac
  owner=${identity%%/*}
  repo=${identity#*/}
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  case "$owner" in
    *[![:alnum:]-]*) return 1 ;;
  esac
  case "$repo" in
    *[![:alnum:]._-]*) return 1 ;;
  esac
}

same_repo_identity() {
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}

refuse() {
  echo "update refused: $*" >&2
  exit 1
}

preflight_firstmate() {
  local default current local_rev tracked_rev dirty fetch_out
  git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || refuse "firstmate root is not a git checkout"
  git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1 \
    || refuse "firstmate checkout has no origin remote"
  default=$(default_branch "$FM_ROOT") \
    || refuse "cannot determine the local default branch"
  current=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$current" ] || refuse "firstmate checkout has detached HEAD, expected $default"
  [ "$current" = "$default" ] \
    || refuse "firstmate checkout is on $current, expected $default"
  dirty=$(dirty_status "$FM_ROOT" no || true)
  [ -z "$dirty" ] || refuse "firstmate checkout has a dirty working tree"

  if ! fetch_out=$(git -C "$FM_ROOT" fetch origin --prune --quiet 2>&1); then
    refuse "cannot refresh origin before remote update: $(first_line "$fetch_out")"
  fi
  git -C "$FM_ROOT" rev-parse --verify --quiet "origin/$default^{commit}" >/dev/null \
    || refuse "refreshed origin/$default does not exist"
  local_rev=$(git -C "$FM_ROOT" rev-parse HEAD)
  tracked_rev=$(git -C "$FM_ROOT" rev-parse "origin/$default")
  if [ "$local_rev" != "$tracked_rev" ] \
    && ! git -C "$FM_ROOT" merge-base --is-ancestor HEAD "origin/$default" 2>/dev/null; then
    refuse "local $default has unlanded or divergent commits relative to origin/$default"
  fi
  printf '%s\n' "$default"
}

sync_github_fork_if_needed() {
  local local_default=$1 origin_slug=$2 upstream_url=$3
  local metadata api_origin is_fork api_default api_parent api_parent_owner configured_parent
  local rest_is_fork rest_parent _rest_source
  local before_oid after_oid sync_base sync_parent sync_default

  command -v gh >/dev/null 2>&1 \
    || refuse "origin is on github.com but gh is unavailable"
  if ! metadata=$(gh repo view "$origin_slug" \
    --json nameWithOwner,isFork,defaultBranchRef,parent \
    --jq '[.nameWithOwner, (.isFork|tostring), .defaultBranchRef.name, (.parent.nameWithOwner // "")] | @tsv' \
    2>&1); then
    refuse "GitHub origin inspection failed: $(first_line "$metadata")"
  fi
  IFS=$'\t' read -r api_origin is_fork api_default api_parent <<< "$metadata"
  [ -n "$api_origin" ] && [ -n "$api_default" ] \
    || refuse "GitHub origin inspection returned incomplete metadata"
  same_repo_identity "$api_origin" "$origin_slug" \
    || refuse "GitHub API resolved $api_origin, expected $origin_slug"
  [ "$api_default" = "$local_default" ] \
    || refuse "unsupported topology: GitHub default $api_default differs from local $local_default"

  if [ "$is_fork" != true ]; then
    [ "$is_fork" = false ] \
      || refuse "GitHub origin inspection returned invalid fork state: $is_fork"
    echo "origin: github $api_origin (direct)"
    if [ -n "$upstream_url" ]; then
      echo "upstream: configured $(remote_identity "$upstream_url")"
    else
      echo "upstream: none"
    fi
    echo "fork-sync: not applicable"
    return 0
  fi

  if [ -z "$api_parent" ]; then
    if ! metadata=$(gh api "repos/$api_origin" \
      --jq '[ (.fork|tostring), (.parent.full_name // ""), (.source.full_name // "") ] | @tsv' \
      2>&1); then
      refuse "GitHub REST fork inspection failed: $(first_line "$metadata")"
    fi
    IFS=$'\t' read -r rest_is_fork rest_parent _rest_source <<< "$metadata"
    [ "$rest_is_fork" = true ] \
      || refuse "GitHub REST fork inspection returned invalid fork state: $rest_is_fork"
    github_repo_identity_is_valid "$rest_parent" \
      || refuse "GitHub REST fork inspection did not identify a valid parent"
    if same_repo_identity "$rest_parent" "$api_origin"; then
      refuse "GitHub REST fork inspection returned malformed self-parent identity"
    fi
    api_parent=$rest_parent
  fi
  github_repo_identity_is_valid "$api_parent" \
    || refuse "GitHub origin inspection returned invalid parent identity: $api_parent"
  api_parent_owner=${api_parent%%/*}
  if [ -n "$upstream_url" ]; then
    configured_parent=$(github_slug_from_url "$upstream_url" || true)
    [ -n "$configured_parent" ] \
      || refuse "unsupported topology: GitHub fork has a non-GitHub configured upstream"
    same_repo_identity "$configured_parent" "$api_parent" \
      || refuse "unsupported topology: configured upstream $configured_parent differs from GitHub parent $api_parent"
  fi

  echo "origin: github $api_origin (fork)"
  echo "upstream: github $api_parent"
  if ! before_oid=$(gh api "repos/$api_origin/commits/$api_default" --jq .sha 2>&1); then
    refuse "GitHub fork tip inspection failed: $(first_line "$before_oid")"
  fi
  case "$before_oid" in
    ''|*[!0-9a-fA-F]*) refuse "GitHub fork tip inspection returned an invalid commit ID" ;;
  esac
  if ! sync_base=$(gh api --method POST "repos/$api_origin/merge-upstream" \
    -f "branch=$api_default" --jq .base_branch 2>&1); then
    refuse "GitHub fork sync failed; unresolved downstream divergence requires a reviewed upstream-integration branch/PR before retry: $(first_line "$sync_base")"
  fi
  case "$sync_base" in
    *:*)
      sync_parent=${sync_base%:*}
      sync_default=${sync_base##*:}
      ;;
    *) refuse "GitHub fork sync returned malformed base branch: $sync_base" ;;
  esac
  case "$sync_parent" in
    ''|*[![:alnum:]-]*) refuse "GitHub fork sync returned malformed parent owner: $sync_parent" ;;
  esac
  [ "$(printf '%s' "$sync_parent" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$api_parent_owner" | tr '[:upper:]' '[:lower:]')" ] \
    || refuse "GitHub fork sync parent owner $sync_parent differs from GitHub parent owner $api_parent_owner"
  [ "$sync_default" = "$api_default" ] \
    || refuse "GitHub fork sync returned base branch $sync_default, expected $api_default"
  if ! after_oid=$(gh api "repos/$api_origin/commits/$api_default" --jq .sha 2>&1); then
    refuse "GitHub fork post-sync inspection failed: $(first_line "$after_oid")"
  fi
  case "$after_oid" in
    ''|*[!0-9a-fA-F]*) refuse "GitHub fork post-sync inspection returned an invalid commit ID" ;;
  esac
  if [ "$before_oid" = "$after_oid" ]; then
    echo "fork-sync: already current $api_origin with $api_parent"
  else
    echo "fork-sync: updated ${before_oid:0:12}..${after_oid:0:12} $api_origin from $api_parent"
  fi
}

# --- origin and main firstmate repo ---------------------------------------

local_default=$(preflight_firstmate)
origin_url=$(git -C "$FM_ROOT" config --get remote.origin.url)
upstream_url=$(git -C "$FM_ROOT" config --get remote.upstream.url 2>/dev/null || true)
origin_slug=$(github_slug_from_url "$origin_url" || true)
if [ -n "$origin_slug" ]; then
  sync_github_fork_if_needed "$local_default" "$origin_slug" "$upstream_url"
else
  echo "origin: non-GitHub $(remote_identity "$origin_url")"
  if [ -n "$upstream_url" ]; then
    echo "upstream: configured $(remote_identity "$upstream_url")"
  else
    echo "upstream: none"
  fi
  echo "fork-sync: not applicable"
fi

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "skipped" ]; then
  refuse "firstmate did not fast-forward"
fi
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""
update_errors=0

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
while IFS='|' read -r id home window meta; do
  if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
  process_secondmate "$id" "$home" "$window" origin no
  [ "$FF_STATUS" != "skipped" ] || update_errors=1
done < <(live_secondmate_meta_records "$STATE" "$SECONDMATES_MD")

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      update_errors=1
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST (${remote_result#synced: })"
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
            fi
            ;;
          current:*) echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })" ;;
          *)
            echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2
            update_errors=1
            ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
        update_errors=1
      fi
    else
      process_secondmate "$id" "$home" "" origin no
      [ "$FF_STATUS" != "skipped" ] || update_errors=1
    fi
  done < "$SECONDMATES_MD"
fi

[ "$update_errors" -eq 0 ] \
  || refuse "one or more registered secondmate homes could not fast-forward"

# --- inherited local material --------------------------------------------

echo "config-convergence: starting"
if ! "$CONFIG_PUSH" --include-registered; then
  refuse "inherited config convergence failed"
fi
echo "config-convergence: complete"

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
