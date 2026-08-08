#!/usr/bin/env bash
# Report and validate the permanent fork-main divergence set.
#
# Usage:
#   fm-fork-status.sh [--repo <path>] [--fork-ref <ref>] [--upstream-ref <ref>] [--refresh] [--json] [--facts-only]
#   fm-fork-status.sh --check-upstream [--repo <path>] [--refresh]
#
# The factual patch set comes from `git cherry upstream/<default>
# origin/<default>`. The tracked fork-divergences.json manifest supplies only
# Git's missing intent: one named topic, class, pull-request disposition,
# falsifiable retirement condition, path ownership, and integration merges.
# Manifest disagreement is an unhealthy result, never silently repaired.
#
# --refresh fetches origin and upstream and verifies recorded GitHub PR
# dispositions with gh-axi. Without it, the report is deterministic over local
# refs and recorded dispositions. --check-upstream is the cheap self-update and
# startup probe: it reports whether upstream is already an ancestor of the fork
# and never merges or writes a file. --facts-only keeps rising divergence count
# visible but makes the exit status depend only on Git/manifest consistency and
# superseded debt; candidate preparation uses it when adding or retiring an
# already-authorized topic would otherwise make trend an inappropriate blocker.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO=$FM_ROOT
REFRESH=0
JSON=0
CHECK_UPSTREAM=0
FACTS_ONLY=0
FORK_REF=${FM_FORK_HEAD_REF:-}
UPSTREAM_REF_OVERRIDE=${FM_FORK_UPSTREAM_REF:-}
MANIFEST=${FM_FORK_MANIFEST_OVERRIDE:-}

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-fork-status: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a path"; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#*=}; shift ;;
    --refresh) REFRESH=1; shift ;;
    --fork-ref) [ "$#" -ge 2 ] || die "--fork-ref requires a ref"; FORK_REF=$2; shift 2 ;;
    --fork-ref=*) FORK_REF=${1#*=}; shift ;;
    --upstream-ref) [ "$#" -ge 2 ] || die "--upstream-ref requires a ref"; UPSTREAM_REF_OVERRIDE=$2; shift 2 ;;
    --upstream-ref=*) UPSTREAM_REF_OVERRIDE=${1#*=}; shift ;;
    --json) JSON=1; shift ;;
    --facts-only) FACTS_ONLY=1; shift ;;
    --check-upstream) CHECK_UPSTREAM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPO=$(cd "$REPO" 2>/dev/null && pwd -P) || die "repository path is unavailable: $REPO"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree: $REPO"
[ -n "$MANIFEST" ] || MANIFEST="$REPO/fork-divergences.json"

remote_branch() { # <remote>
  local remote=$1 ref branch
  ref=$(git -C "$REPO" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#"$remote"/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$REPO" rev-parse --verify --quiet "refs/remotes/$remote/$branch^{commit}" >/dev/null; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

origin_url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
upstream_url=$(git -C "$REPO" remote get-url upstream 2>/dev/null || true)
if [ -z "$upstream_url" ]; then
  if [ "$CHECK_UPSTREAM" -eq 1 ]; then
    printf 'upstream-integration: disabled (no upstream remote)\n'
    exit 0
  fi
  die "upstream remote is missing"
fi
[ -n "$origin_url" ] || die "origin remote is missing"
[ "$origin_url" != "$upstream_url" ] || die "origin and upstream resolve to the same URL"
"$SCRIPT_DIR/fm-fork-remotes.sh" check "$REPO" >/dev/null \
  || die "fork remote topology is not validated"

if [ "$REFRESH" -eq 1 ]; then
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune origin || die "origin fetch failed"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune upstream || die "upstream fetch failed"
fi

origin_branch=$(remote_branch origin) || die "cannot determine origin's default branch"
upstream_branch=$(remote_branch upstream) || die "cannot determine upstream's default branch"
ORIGIN_REF=${FORK_REF:-"origin/$origin_branch"}
UPSTREAM_REF=${UPSTREAM_REF_OVERRIDE:-"upstream/$upstream_branch"}
origin_sha=$(git -C "$REPO" rev-parse "$ORIGIN_REF") || die "cannot read $ORIGIN_REF"
upstream_sha=$(git -C "$REPO" rev-parse "$UPSTREAM_REF") || die "cannot read $UPSTREAM_REF"

if [ "$CHECK_UPSTREAM" -eq 1 ]; then
  if git -C "$REPO" merge-base --is-ancestor "$UPSTREAM_REF" "$ORIGIN_REF" 2>/dev/null; then
    printf 'upstream-integration: current upstream=%s fork=%s\n' "${upstream_sha%%????????????????????????????????}" "${origin_sha%%????????????????????????????????}"
  else
    printf 'upstream-integration: required upstream=%s fork=%s (prepare an isolated validated merge; live homes remain fast-forward-only)\n' \
      "${upstream_sha%%????????????????????????????????}" "${origin_sha%%????????????????????????????????}"
  fi
  exit 0
fi

[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || die "manifest is missing or unsafe: $MANIFEST"
case "$MANIFEST" in
  "$REPO"/*) MANIFEST_REL=${MANIFEST#"$REPO"/} ;;
  *) die "manifest must be inside the repository" ;;
esac
git -C "$REPO" ls-files --error-unmatch -- "$MANIFEST_REL" >/dev/null 2>&1 \
  || die "manifest is not tracked: $MANIFEST_REL"
command -v jq >/dev/null 2>&1 || die "jq is required"

if ! jq -e '
  .schema == "firstmate.fork-divergences.v1" and
  (.upstream_syncs | type == "array" and length <= 20) and
  (.divergences | type == "array") and
  ([.divergences[].id] | length == (unique | length)) and
  all(.divergences[];
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (.summary | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
    (.class == "pending" or .class == "rejected-but-retained" or .class == "private" or .class == "superseded") and
    (.topic == ("fm/divergence/" + .id)) and
    (.introduced | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
    (.retire_when | type == "string" and length >= 12 and (test("[[:cntrl:]]") | not) and (test("(?i)(review periodically|revisit later|monitor this|^tbd$|^todo$)") | not)) and
    (.paths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (test("[[:cntrl:]]") | not) and (startswith("/") | not) and (contains("..") | not))) and
    (if .class == "private" then (.upstream_pr == null or (.upstream_pr | type == "object"))
     else (.upstream_pr | type == "object" and (.url | type == "string" and test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$")) and (.disposition == "open" or .disposition == "rejected" or .disposition == "merged" or .disposition == "closed")) end)
  ) and
  all(.upstream_syncs[];
    (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
    (.fork_before | type == "string" and test("^[0-9a-f]{7,64}$")) and
    (.upstream_before | type == "string" and test("^[0-9a-f]{7,64}$")) and
    (.upstream_after | type == "string" and test("^[0-9a-f]{7,64}$")) and
    (.touched | type == "array" and all(.[]; type == "string")) and
    ((.validation_pr // null) == null or (.validation_pr | type == "string" and test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$")))
  )
' "$MANIFEST" >/dev/null 2>&1; then
  die "manifest does not satisfy firstmate.fork-divergences.v1"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-status.XXXXXX") || die "cannot create temporary state"
trap 'rm -rf "$TMP"' EXIT
ERRORS="$TMP/errors"
OWNED="$TMP/owned"
CHERRY="$TMP/cherry"
RETIRED="$TMP/retired"
: > "$ERRORS"
: > "$OWNED"
: > "$RETIRED"
git -C "$REPO" cherry -v "$UPSTREAM_REF" "$ORIGIN_REF" > "$CHERRY" \
  || die "git cherry failed"

# `git revert -m 1 <topic-merge>` intentionally leaves both the topic patch and
# its inverse revert in history. They remain `git cherry +` facts even though
# their net divergence is gone. Recognize only Git's exact, reachable merge-
# revert relationship and retire that pair from active ownership; an arbitrary
# unowned commit is never hidden by message convention alone.
while IFS= read -r line || [ -n "$line" ]; do
  [ "${line%% *}" = + ] || continue
  rest=${line#? }
  revert_sha=${rest%% *}
  reverted_merge=$(git -C "$REPO" show -s --format=%B "$revert_sha" \
    | sed -n 's/^This reverts commit \([0-9a-f][0-9a-f]*\), reversing$/\1/p' \
    | head -1)
  [ -n "$reverted_merge" ] || continue
  git -C "$REPO" merge-base --is-ancestor "$reverted_merge" "$ORIGIN_REF" 2>/dev/null || continue
  git -C "$REPO" rev-list --first-parent "$ORIGIN_REF" | grep -Fxq "$revert_sha" || continue
  revert_parent_line=$(git -C "$REPO" rev-list --parents -n1 "$revert_sha" 2>/dev/null || true)
  # Git emits a space-delimited list of hexadecimal object IDs.
  # shellcheck disable=SC2086
  set -- $revert_parent_line
  [ "$#" -eq 2 ] || continue
  parent_line=$(git -C "$REPO" rev-list --parents -n1 "$reverted_merge" 2>/dev/null || true)
  # shellcheck disable=SC2086
  set -- $parent_line
  [ "$#" -eq 3 ] || continue
  first_parent=$2
  second_parent=$3
  git -C "$REPO" merge-base --is-ancestor "$second_parent" "$UPSTREAM_REF" 2>/dev/null && continue
  expected_patch=$(git -C "$REPO" diff "$reverted_merge" "$first_parent" -- . ":(top,exclude,literal)$MANIFEST_REL" | git patch-id --stable | awk 'NR == 1 { print $1 }')
  actual_patch=$(git -C "$REPO" diff "$revert_sha^" "$revert_sha" -- . ":(top,exclude,literal)$MANIFEST_REL" | git patch-id --stable | awk 'NR == 1 { print $1 }')
  [ -n "$expected_patch" ] && [ "$actual_patch" = "$expected_patch" ] || continue
  printf '%s\n' "$revert_sha" >> "$RETIRED"
  topic_base=$(git -C "$REPO" merge-base "$UPSTREAM_REF" "$second_parent" 2>/dev/null || true)
  [ -n "$topic_base" ] || continue
  git -C "$REPO" rev-list --no-merges "$topic_base..$second_parent" >> "$RETIRED"
done < "$CHERRY"
sort -u "$RETIRED" -o "$RETIRED"
awk '$1 == "+" { print $2 }' "$CHERRY" > "$TMP/plus"
grep -Fxf "$TMP/plus" "$RETIRED" > "$TMP/retired-plus" || true
mv "$TMP/retired-plus" "$RETIRED"

add_error() {
  printf '%s\n' "$*" >> "$ERRORS"
}

topic_ref() { # <topic>
  local topic=$1
  if git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$topic^{commit}" >/dev/null; then
    printf 'refs/remotes/origin/%s\n' "$topic"
    return 0
  fi
  if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$topic^{commit}" >/dev/null; then
    printf 'refs/heads/%s\n' "$topic"
    return 0
  fi
  return 1
}

path_covered() { # <manifest-path> <actual-path>
  local spec=$1 actual=$2 prefix
  case "$spec" in
    */'**') prefix=${spec%'**'}; case "$actual" in "$prefix"*) return 0 ;; esac ;;
    */) case "$actual" in "$spec"*) return 0 ;; esac ;;
    *) [ "$actual" = "$spec" ] && return 0 ;;
  esac
  return 1
}

# Resolve every factual non-equivalent patch to exactly one canonical topic.
while IFS= read -r line || [ -n "$line" ]; do
  [ "${line%% *}" = + ] || continue
  rest=${line#? }
  sha=${rest%% *}
  grep -Fxq "$sha" "$RETIRED" && continue
  owners=
  while IFS=$'\t' read -r id topic; do
    [ -n "$id" ] || continue
    ref=$(topic_ref "$topic" || true)
    [ -n "$ref" ] || continue
    if git -C "$REPO" merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then
      owners="${owners}${owners:+ }$id"
    fi
  done < <(jq -r '.divergences[] | [.id,.topic] | @tsv' "$MANIFEST")
  case "$owners" in
    '') add_error "unowned non-equivalent patch $sha" ;;
    *' '*) add_error "non-equivalent patch $sha has multiple manifest owners: $owners" ;;
    *) printf '%s\t%s\n' "$sha" "$owners" >> "$OWNED" ;;
  esac
done < "$CHERRY"

# Validate every manifest unit against refs, patch ownership, a reachable
# branch-level integration merge, and declared path coverage.
while IFS=$'\t' read -r id class topic; do
  [ -n "$id" ] || continue
  ref=$(topic_ref "$topic" || true)
  if [ -z "$ref" ]; then
    add_error "manifest unit $id is missing canonical topic $topic"
    continue
  fi
  owned_count=$(awk -F '\t' -v id="$id" '$2 == id { n++ } END { print n+0 }' "$OWNED")
  if [ "$owned_count" -eq 0 ] && [ "$class" != superseded ]; then
    add_error "manifest unit $id owns no non-equivalent patch; reclassify or remove it"
  fi
  if [ "$owned_count" -gt 1 ]; then
    add_error "manifest unit $id has $owned_count non-equivalent commits; git cherry cannot prove an aggregate upstream squash equivalent"
  fi
  integration_found=0
  while IFS= read -r merge; do
    parent_line=$(git -C "$REPO" rev-list --parents -n 1 "$merge")
    # Git emits a space-delimited list of hexadecimal object IDs.
    # shellcheck disable=SC2086
    set -- $parent_line
    [ "$#" -eq 3 ] || continue
    second_parent=$3
    # An integration merge's second parent belongs to this topic's patch side,
    # not merely to upstream history that the topic also contains.
    if git -C "$REPO" merge-base --is-ancestor "$second_parent" "$ref" 2>/dev/null \
        && ! git -C "$REPO" merge-base --is-ancestor "$second_parent" "$UPSTREAM_REF" 2>/dev/null; then
      integration_found=1
      break
    fi
  done < <(git -C "$REPO" rev-list --first-parent --merges "$ORIGIN_REF")
  [ "$integration_found" -eq 1 ] || add_error "manifest unit $id has no reachable branch-level integration merge for $topic"

  while IFS=$'\t' read -r patch_sha owner; do
    [ "$owner" = "$id" ] || continue
    while IFS= read -r changed_path; do
      [ -n "$changed_path" ] || continue
      covered=0
      while IFS= read -r spec; do
        if path_covered "$spec" "$changed_path"; then covered=1; break; fi
      done < <(jq -r --arg id "$id" '.divergences[] | select(.id == $id) | .paths[]' "$MANIFEST")
      [ "$covered" -eq 1 ] || add_error "manifest unit $id does not cover changed path $changed_path"
    done < <(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$patch_sha")
  done < "$OWNED"
done < <(jq -r '.divergences[] | [.id,.class,.topic] | @tsv' "$MANIFEST")

# Optional live PR disposition check. It is evidence only and never updates the
# tracked manifest behind the operator's back.
if [ "$REFRESH" -eq 1 ]; then
  while IFS=$'\t' read -r id url recorded; do
    [ -n "$url" ] || continue
    path=${url#https://github.com/}
    owner=${path%%/*}; path=${path#*/}; repo_name=${path%%/*}; number=${url##*/}
    live=$(gh-axi api "/repos/$owner/$repo_name/pulls/$number" \
      --jq 'if .merged_at != null then "merged" elif .state == "open" then "open" else "closed" end' 2>/dev/null || true)
    [ -n "$live" ] || { add_error "manifest unit $id pull request disposition could not be refreshed"; continue; }
    if [ "$recorded" = rejected ]; then
      [ "$live" = closed ] || add_error "manifest unit $id records rejected but live pull request is $live"
    elif [ "$recorded" != "$live" ]; then
      add_error "manifest unit $id records pull request $recorded but live pull request is $live"
    fi
  done < <(jq -r '.divergences[] | select(.upstream_pr != null) | [.id,.upstream_pr.url,.upstream_pr.disposition] | @tsv' "$MANIFEST")
fi

raw_plus_total=$(awk '$1 == "+" { n++ } END { print n+0 }' "$CHERRY")
retired_patch_count=$(awk 'NF { n++ } END { print n+0 }' "$RETIRED")
raw_plus=$((raw_plus_total - retired_patch_count))
active_ids=$(awk -F '\t' '{ print $2 }' "$OWNED" | sort -u)
active_count=$(printf '%s\n' "$active_ids" | awk 'NF { n++ } END { print n+0 }')
pending_count=$(jq '[.divergences[] | select(.class == "pending")] | length' "$MANIFEST")
rejected_count=$(jq '[.divergences[] | select(.class == "rejected-but-retained")] | length' "$MANIFEST")
private_count=$(jq '[.divergences[] | select(.class == "private")] | length' "$MANIFEST")
superseded_count=$(jq '[.divergences[] | select(.class == "superseded")] | length' "$MANIFEST")

oldest_pending=$(jq -r '[.divergences[] | select(.class == "pending")] | sort_by(.introduced) | first // empty | [.id,.introduced] | @tsv' "$MANIFEST")
oldest_id=${oldest_pending%%$'\t'*}
oldest_date=
[ -z "$oldest_pending" ] || oldest_date=${oldest_pending#*$'\t'}
oldest_age=none
oldest_age_json=null
if [ -n "$oldest_date" ]; then
  introduced_epoch=$(jq -nr --arg d "${oldest_date}T00:00:00Z" '$d | fromdateiso8601' 2>/dev/null || echo '')
  case "$introduced_epoch" in
    ''|*[!0-9]*) oldest_age=unknown ;;
    *) oldest_age=$(( ($(date +%s) - introduced_epoch) / 86400 )); oldest_age_json=$oldest_age ;;
  esac
fi

trend=no-baseline
baseline_count=
last_sync=$(jq -c '.upstream_syncs | last // empty' "$MANIFEST")
if [ -n "$last_sync" ]; then
  fork_before=$(printf '%s' "$last_sync" | jq -r .fork_before)
  upstream_before=$(printf '%s' "$last_sync" | jq -r .upstream_before)
  if git -C "$REPO" rev-parse --verify --quiet "$fork_before^{commit}" >/dev/null \
      && git -C "$REPO" rev-parse --verify --quiet "$upstream_before^{commit}" >/dev/null; then
    baseline_count=$(git -C "$REPO" cherry "$upstream_before" "$fork_before" | awk '$1 == "+" { n++ } END { print n+0 }')
    if [ "$raw_plus" -lt "$baseline_count" ]; then trend=down
    elif [ "$raw_plus" -gt "$baseline_count" ]; then trend=up
    else trend=unchanged
    fi
  fi
fi

last_touched=$(jq -r '.upstream_syncs | last // empty | .touched // [] | join(",")' "$MANIFEST")
last_touched_count=$(jq '.upstream_syncs | last // {touched:[]} | .touched | length' "$MANIFEST")
error_count=$(awk 'NF { n++ } END { print n+0 }' "$ERRORS")
local_main=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$origin_branch^{commit}" 2>/dev/null || true)
if [ -z "$FORK_REF" ] && [ -n "$local_main" ] && [ "$local_main" != "$origin_sha" ]; then
  add_error "local $origin_branch does not match $ORIGIN_REF"
  error_count=$((error_count + 1))
fi

if [ "$JSON" -eq 1 ]; then
  errors_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$ERRORS")
  touched_json=$(jq '.upstream_syncs | last // {touched:[]} | .touched' "$MANIFEST")
  jq -n \
    --arg schema firstmate.fork-health.v1 \
    --arg origin "$ORIGIN_REF" --arg origin_sha "$origin_sha" \
    --arg upstream "$UPSTREAM_REF" --arg upstream_sha "$upstream_sha" \
    --arg trend "$trend" --arg oldest_pending "${oldest_id:-}" \
    --arg oldest_pending_date "${oldest_date:-}" --argjson oldest_pending_age "$oldest_age_json" \
    --argjson active "$active_count" --argjson patches "$raw_plus" --argjson retired_patches "$retired_patch_count" \
    --argjson pending "$pending_count" --argjson rejected "$rejected_count" \
    --argjson private "$private_count" --argjson superseded "$superseded_count" \
    --argjson touched "$touched_json" --argjson errors "$errors_json" \
    '{schema:$schema, refs:{fork:$origin,fork_sha:$origin_sha,upstream:$upstream,upstream_sha:$upstream_sha}, retained:{units:$active,patches:$patches,retired_history_patches:$retired_patches,trend:$trend,classes:{pending:$pending,"rejected-but-retained":$rejected,private:$private,superseded:$superseded}}, oldest_pending:{id:$oldest_pending,date:$oldest_pending_date,age_days:$oldest_pending_age}, last_upstream_merge:{touched:$touched}, errors:$errors, healthy:($errors|length == 0 and $superseded == 0 and $trend != "up")}'
else
  printf 'Fork divergence health: retained=%s patches=%s retired-history-patches=%s trend=%s superseded=%s errors=%s\n' \
    "$active_count" "$raw_plus" "$retired_patch_count" "$trend" "$superseded_count" "$error_count"
  printf 'Refs: fork=%s@%s upstream=%s@%s\n' "$ORIGIN_REF" "${origin_sha%%????????????????????????????????}" "$UPSTREAM_REF" "${upstream_sha%%????????????????????????????????}"
  printf 'Classes: pending=%s rejected-but-retained=%s private=%s superseded=%s\n' \
    "$pending_count" "$rejected_count" "$private_count" "$superseded_count"
  if [ -n "$oldest_id" ]; then
    printf 'Oldest pending: %s introduced=%s age_days=%s\n' "$oldest_id" "$oldest_date" "$oldest_age"
  else
    printf 'Oldest pending: none\n'
  fi
  printf 'Last upstream merge touched: %s%s\n' "$last_touched_count" "${last_touched:+ ($last_touched)}"
  while IFS=$'\t' read -r id class summary topic retire pr disposition; do
    [ -n "$id" ] || continue
    printf '%s [%s] topic=%s upstream=%s%s\n' "$id" "$class" "$topic" "${disposition:-private}" "${pr:+ $pr}"
    printf '  does: %s\n' "$summary"
    printf '  retire when: %s\n' "$retire"
  done < <(jq -r '.divergences[] | [.id,.class,.summary,.topic,.retire_when,(.upstream_pr.url // ""),(.upstream_pr.disposition // "")] | @tsv' "$MANIFEST")
  if [ "$last_touched_count" -gt 0 ] && [ -n "$last_sync" ]; then
    fork_before=$(printf '%s' "$last_sync" | jq -r .fork_before)
    upstream_before=$(printf '%s' "$last_sync" | jq -r .upstream_before)
    upstream_after=$(printf '%s' "$last_sync" | jq -r .upstream_after)
    printf 'Relevance review: git -C %s range-diff --remerge-diff %s..%s %s..%s\n' \
      "$REPO" "$upstream_before" "$fork_before" "$upstream_after" "$ORIGIN_REF"
  fi
  if [ "$error_count" -gt 0 ]; then
    printf 'Manifest/Git mismatches:\n'
    sed 's/^/  - /' "$ERRORS"
  fi
fi

[ "$error_count" -eq 0 ] && [ "$superseded_count" -eq 0 ] \
  && { [ "$FACTS_ONLY" -eq 1 ] || [ "$trend" != up ]; }
