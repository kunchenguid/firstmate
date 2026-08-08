#!/usr/bin/env bash
# Report and validate the permanent fork-main divergence set.
#
# Usage:
#   fm-fork-status.sh [--repo <path>] [--fork-ref <ref>] [--upstream-ref <ref>] [--refresh] [--json] [--facts-only]
#   fm-fork-status.sh --check-upstream [--repo <path>] [--refresh]
#
# `git cherry upstream/<default> origin/<default>` supplies one fact only: which
# commits have no equivalent upstream patch. The tracked fork-divergences.json
# manifest supplies meaning: the canonical topic patches the fork intends to
# carry, their class, pull-request disposition, retirement condition, paths, and
# integration merges. A raw non-upstream commit outside those topics is a visible
# signal, not automatically a carried divergence or a health failure. Descendant
# validation fixes and manifest-only governance commits are attributed as
# integration artifacts. retired_upstream records add the one equivalence fact
# Git can no longer recompute after an integration merge, and every one of them
# is re-proved here before its patch leaves the factual non-upstream count.
#
# --refresh fetches origin and upstream and verifies recorded GitHub PR
# dispositions with gh-axi. Without it, the report is deterministic over local
# refs and recorded dispositions. gh-axi's current API serializer is parsed as
# one complete, untruncated scalar envelope rather than compared as raw stdout.
# --check-upstream is the cheap self-update and startup probe: it reports whether upstream is already an ancestor of the fork
# and never merges or writes a file. --facts-only keeps rising divergence count
# visible but makes the exit status depend only on Git/manifest consistency and
# superseded debt; candidate preparation uses it when adding or retiring an
# already-authorized topic would otherwise make trend an inappropriate blocker.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fork-lib.sh
. "$SCRIPT_DIR/fm-fork-lib.sh"
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

origin_branch=$(fm_fork_remote_branch "$REPO" origin) || die "cannot determine origin's default branch"
upstream_branch=$(fm_fork_remote_branch "$REPO" upstream) || die "cannot determine upstream's default branch"
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
  ((.retired_upstream // []) | type == "array") and
  ([.divergences[].id] + [(.retired_upstream // [])[].id] | length == (unique | length)) and
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
  all((.retired_upstream // [])[];
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (.topic == ("fm/divergence/" + .id)) and
    (.summary | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
    (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
    (.fork_patch | type == "string" and test("^[0-9a-f]{40,64}$")) and
    (.upstream_patch | type == "string" and test("^[0-9a-f]{40,64}$")) and
    (.patch_id | type == "string" and test("^[0-9a-f]{40,64}$"))
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
SIGNALS="$TMP/signals"
OWNED="$TMP/owned"
ARTIFACTS="$TMP/artifacts"
KNOWN_INTEGRATIONS="$TMP/known-integrations"
CHERRY="$TMP/cherry"
RETIRED="$TMP/retired"
ACCEPTED="$TMP/accepted"
PROVED="$TMP/proved"
EXCLUDED="$TMP/excluded"
: > "$ERRORS"
: > "$SIGNALS"
: > "$OWNED"
: > "$ARTIFACTS"
: > "$KNOWN_INTEGRATIONS"
: > "$RETIRED"
: > "$ACCEPTED"
: > "$PROVED"
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
  printf '%s\n' "$reverted_merge" >> "$KNOWN_INTEGRATIONS"
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

add_signal() {
  printf '%s\n' "$*" >> "$SIGNALS"
}

# Upstream acceptance is the documented retirement path, but it stops being
# measurable from the merged refs: once the integration merge lands, upstream is
# an ancestor of fork main and `git cherry`'s documented <head>..<upstream>
# equivalence search space is empty, so the fork's own copy of an accepted patch
# is a `+` fact forever. fm-fork-merge.sh therefore captured the proof while it
# still existed, and this owner re-derives that proof from reachable Git objects
# rather than trusting the record. A record that no longer holds keeps its patch
# counted and named as an error instead of quietly shrinking the divergence set.
while IFS=$'\t' read -r id fork_patch upstream_patch patch_id; do
  [ -n "$id" ] || continue
  if ! git -C "$REPO" rev-parse --verify --quiet "$fork_patch^{commit}" >/dev/null; then
    add_error "accepted-upstream retirement $id names unknown fork patch $fork_patch"
    continue
  fi
  if ! git -C "$REPO" rev-parse --verify --quiet "$upstream_patch^{commit}" >/dev/null; then
    add_error "accepted-upstream retirement $id names unknown upstream commit $upstream_patch"
    continue
  fi
  if ! grep -Fxq "$fork_patch" "$TMP/plus"; then
    add_error "accepted-upstream retirement $id is stale: $fork_patch is not a carried patch on $ORIGIN_REF"
    continue
  fi
  if ! git -C "$REPO" merge-base --is-ancestor "$upstream_patch" "$UPSTREAM_REF" 2>/dev/null; then
    add_error "accepted-upstream retirement $id claims upstream commit $upstream_patch that $UPSTREAM_REF does not contain"
    continue
  fi
  fork_patch_id=$(fm_fork_commit_patch_id "$REPO" "$fork_patch" || true)
  upstream_patch_id=$(fm_fork_commit_patch_id "$REPO" "$upstream_patch" || true)
  if [ "$fork_patch_id" != "$patch_id" ]; then
    add_error "accepted-upstream retirement $id records patch identity $patch_id but fork patch $fork_patch has ${fork_patch_id:-none}"
    continue
  fi
  if [ "$upstream_patch_id" != "$patch_id" ]; then
    add_error "accepted-upstream retirement $id is unproved: upstream commit $upstream_patch has patch identity ${upstream_patch_id:-none}"
    continue
  fi
  printf '%s\t%s\n' "$fork_patch" "$upstream_patch" >> "$PROVED"
  grep -Fxq "$fork_patch" "$RETIRED" || printf '%s\n' "$fork_patch" >> "$ACCEPTED"
done < <(jq -r '.retired_upstream // [] | .[] | [.id,.fork_patch,.upstream_patch,.patch_id] | @tsv' "$MANIFEST")
sort -u "$ACCEPTED" -o "$ACCEPTED"
cat "$RETIRED" "$ACCEPTED" | sort -u > "$EXCLUDED"

# The manifest is the ownership model. `git cherry` still supplies the factual
# set that is not upstream, but it does not decide what those commits mean.
# Resolve each declared unit from its canonical topic first, then classify any
# remaining fork-head commits as visible signals or integration-path artifacts.
while IFS=$'\t' read -r id class topic; do
  [ -n "$id" ] || continue
  ref=$(fm_fork_topic_ref "$REPO" "$topic" || true)
  if [ -z "$ref" ]; then
    add_error "manifest unit $id is missing canonical topic $topic"
    continue
  fi
  topic_cherry="$TMP/topic-$id.cherry"
  git -C "$REPO" cherry "$UPSTREAM_REF" "$ref" > "$topic_cherry" \
    || { add_error "manifest unit $id could not be compared with $UPSTREAM_REF"; continue; }
  owned_count=$(awk '$1 == "+" { n++ } END { print n+0 }' "$topic_cherry")
  if [ "$owned_count" -eq 0 ] && [ "$class" != superseded ]; then
    add_signal "manifest unit $id has no canonical patch outside $UPSTREAM_REF; review whether upstream accepted it"
  elif [ "$owned_count" -gt 1 ]; then
    add_error "manifest unit $id has $owned_count canonical non-equivalent commits; one aggregate patch is required"
  else
    awk -v id="$id" '$1 == "+" { print $2 "\t" id }' "$topic_cherry" >> "$OWNED"
  fi

  integration_found=0
  while IFS= read -r merge; do
    parent_line=$(git -C "$REPO" rev-list --parents -n 1 "$merge")
    # Git emits a space-delimited list of hexadecimal object IDs.
    # shellcheck disable=SC2086
    set -- $parent_line
    [ "$#" -eq 3 ] || continue
    second_parent=$3
    if git -C "$REPO" merge-base --is-ancestor "$second_parent" "$ref" 2>/dev/null \
        && ! git -C "$REPO" merge-base --is-ancestor "$second_parent" "$UPSTREAM_REF" 2>/dev/null; then
      integration_found=1
      printf '%s\n' "$merge" >> "$KNOWN_INTEGRATIONS"
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
        if fm_fork_path_covered "$spec" "$changed_path"; then covered=1; break; fi
      done < <(jq -r --arg id "$id" '.divergences[] | select(.id == $id) | .paths[]' "$MANIFEST")
      [ "$covered" -eq 1 ] || add_error "manifest unit $id does not cover changed path $changed_path"
    done < <(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$patch_sha")
  done < "$OWNED"
done < <(jq -r '.divergences[] | [.id,.class,.topic] | @tsv' "$MANIFEST")

while IFS=$'\t' read -r sha owners; do
  [ -n "$sha" ] || continue
  count=$(printf '%s\n' "$owners" | awk -F ',' '{ print NF }')
  [ "$count" -le 1 ] || add_error "canonical patch $sha has multiple manifest owners: $owners"
done < <(awk -F '\t' '{ owner[$1] = owner[$1] sep[$1] $2; sep[$1] = "," } END { for (sha in owner) print sha "\t" owner[sha] }' "$OWNED")

# An upstream-sync merge has no active topic second parent, so derive its anchor
# from the manifest's exact before/after parents. Pipeline fixes descending from
# either this anchor or an active topic integration are attributable to the
# integration path without becoming carried divergences.
while IFS=$'\t' read -r fork_before upstream_after; do
  [ -n "$fork_before" ] || continue
  while IFS= read -r merge; do
    parent_line=$(git -C "$REPO" rev-list --parents -n 1 "$merge")
    # shellcheck disable=SC2086
    set -- $parent_line
    if [ "$#" -eq 3 ] && [ "$2" = "$fork_before" ] && [ "$3" = "$upstream_after" ]; then
      printf '%s\n' "$merge" >> "$KNOWN_INTEGRATIONS"
      break
    fi
  done < <(git -C "$REPO" rev-list --merges "$ORIGIN_REF")
done < <(jq -r '.upstream_syncs[] | [.fork_before,.upstream_after] | @tsv' "$MANIFEST")
sort -u "$KNOWN_INTEGRATIONS" -o "$KNOWN_INTEGRATIONS"

while IFS= read -r line || [ -n "$line" ]; do
  [ "${line%% *}" = + ] || continue
  rest=${line#? }
  sha=${rest%% *}
  grep -Fxq "$sha" "$EXCLUDED" && continue
  awk -F '\t' -v sha="$sha" '$1 == sha { found=1 } END { exit !found }' "$OWNED" && continue
  artifact_kind=unattributed
  artifact_anchor=
  while IFS= read -r anchor; do
    [ -n "$anchor" ] || continue
    if git -C "$REPO" merge-base --is-ancestor "$anchor" "$sha" 2>/dev/null; then
      artifact_kind=integration-path
      artifact_anchor=$anchor
      break
    fi
  done < "$KNOWN_INTEGRATIONS"
  changed=$(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$sha")
  if [ -n "$changed" ] && [ "$changed" = "$MANIFEST_REL" ]; then
    artifact_kind=manifest-governance
  fi
  printf '%s\t%s\t%s\n' "$sha" "$artifact_kind" "$artifact_anchor" >> "$ARTIFACTS"
  if [ "$artifact_kind" = integration-path ]; then
    add_signal "non-upstream commit $sha is an integration-path artifact after $artifact_anchor, not a carried divergence"
  elif [ "$artifact_kind" = manifest-governance ]; then
    add_signal "non-upstream commit $sha is a manifest-governance artifact, not a carried divergence"
  else
    add_signal "non-upstream commit $sha is not represented by a canonical manifest topic"
  fi
done < "$CHERRY"

# Optional live PR disposition check. It is evidence only and never updates the
# tracked manifest behind the operator's back.
if [ "$REFRESH" -eq 1 ]; then
  while IFS=$'\t' read -r id url recorded; do
    [ -n "$url" ] || continue
    path=${url#https://github.com/}
    owner=${path%%/*}; path=${path#*/}; repo_name=${path%%/*}; number=${url##*/}
    live_output=$(gh-axi api "/repos/$owner/$repo_name/pulls/$number" \
      --jq 'if .merged_at != null then "merged" elif .state == "open" then "open" else "closed" end' 2>/dev/null || true)
    live=$(printf '%s\n' "$live_output" | fm_fork_gh_axi_scalar || true)
    case "$live" in
      open|closed|merged) ;;
      *) add_error "manifest unit $id pull request disposition could not be refreshed from gh-axi's scalar API envelope"; continue ;;
    esac
    if [ "$recorded" = rejected ]; then
      [ "$live" = closed ] || add_error "manifest unit $id records rejected but live pull request is $live"
    elif [ "$recorded" != "$live" ]; then
      add_error "manifest unit $id records pull request $recorded but live pull request is $live"
    fi
  done < <(jq -r '.divergences[] | select(.upstream_pr != null) | [.id,.upstream_pr.url,.upstream_pr.disposition] | @tsv' "$MANIFEST")
fi

raw_plus_total=$(awk '$1 == "+" { n++ } END { print n+0 }' "$CHERRY")
retired_patch_count=$(awk 'NF { n++ } END { print n+0 }' "$RETIRED")
accepted_patch_count=$(awk 'NF { n++ } END { print n+0 }' "$ACCEPTED")
not_upstream_total=$((raw_plus_total - retired_patch_count - accepted_patch_count))
carried_patch_count=$(awk 'NF { n++ } END { print n+0 }' "$OWNED")
active_count=$(jq '[.divergences[] | select(.class != "superseded")] | length' "$MANIFEST")
artifact_count=$(awk 'NF { n++ } END { print n+0 }' "$ARTIFACTS")
signal_count=$(awk 'NF { n++ } END { print n+0 }' "$SIGNALS")
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
    git -C "$REPO" cherry "$upstream_before" "$fork_before" | awk '$1 == "+" { print $2 }' > "$TMP/baseline-plus"
    baseline_count=0
    while IFS=$'\t' read -r carried_sha _; do
      [ -n "$carried_sha" ] || continue
      grep -Fxq "$carried_sha" "$TMP/baseline-plus" && baseline_count=$((baseline_count + 1))
    done < "$OWNED"
    # A retired record can describe a unit that was still carried at this
    # baseline. Count it only when upstream had not accepted the proved patch at
    # that point; integration-path artifacts never enter either side.
    while IFS=$'\t' read -r proved_fork proved_upstream; do
      [ -n "$proved_fork" ] || continue
      grep -Fxq "$proved_fork" "$TMP/baseline-plus" || continue
      if ! git -C "$REPO" merge-base --is-ancestor "$proved_upstream" "$upstream_before" 2>/dev/null; then
        baseline_count=$((baseline_count + 1))
      fi
    done < "$PROVED"
    if [ "$carried_patch_count" -lt "$baseline_count" ]; then trend=down
    elif [ "$carried_patch_count" -gt "$baseline_count" ]; then trend=up
    else trend=unchanged
    fi
  fi
fi

last_touched=$(jq -r '.upstream_syncs | last // empty | .touched // [] | join(",")' "$MANIFEST")
last_touched_count=$(jq '.upstream_syncs | last // {touched:[]} | .touched | length' "$MANIFEST")
local_main=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$origin_branch^{commit}" 2>/dev/null || true)
if [ -z "$FORK_REF" ] && [ -n "$local_main" ] && [ "$local_main" != "$origin_sha" ]; then
  add_error "local $origin_branch does not match $ORIGIN_REF"
fi
error_count=$(awk 'NF { n++ } END { print n+0 }' "$ERRORS")

accepted_record_count=$(jq '.retired_upstream // [] | length' "$MANIFEST")
proved_forks_json=$(awk -F '\t' '{ print $1 }' "$PROVED" | jq -Rsc 'split("\n") | map(select(length > 0))')

if [ "$JSON" -eq 1 ]; then
  errors_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$ERRORS")
  signals_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$SIGNALS")
  artifacts_json=$(jq -Rn '[inputs | split("\t") | {commit:.[0],kind:.[1],anchor:(if .[2] == "" then null else .[2] end)}]' < "$ARTIFACTS")
  touched_json=$(jq '.upstream_syncs | last // {touched:[]} | .touched' "$MANIFEST")
  accepted_json=$(jq -c --argjson proved "$proved_forks_json" \
    '(.retired_upstream // []) | map(.fork_patch as $f | . + {proved: (($proved | index($f)) != null)})' "$MANIFEST")
  jq -n \
    --arg schema firstmate.fork-health.v1 \
    --arg origin "$ORIGIN_REF" --arg origin_sha "$origin_sha" \
    --arg upstream "$UPSTREAM_REF" --arg upstream_sha "$upstream_sha" \
    --arg trend "$trend" --arg oldest_pending "${oldest_id:-}" \
    --arg oldest_pending_date "${oldest_date:-}" --argjson oldest_pending_age "$oldest_age_json" \
    --argjson active "$active_count" --argjson patches "$carried_patch_count" --argjson not_upstream "$not_upstream_total" \
    --argjson artifacts "$artifacts_json" --argjson retired_patches "$retired_patch_count" \
    --argjson accepted_patches "$accepted_patch_count" --argjson accepted "$accepted_json" \
    --argjson pending "$pending_count" --argjson rejected "$rejected_count" \
    --argjson private "$private_count" --argjson superseded "$superseded_count" \
    --argjson touched "$touched_json" --argjson signals "$signals_json" --argjson errors "$errors_json" \
    '{schema:$schema, refs:{fork:$origin,fork_sha:$origin_sha,upstream:$upstream,upstream_sha:$upstream_sha}, retained:{units:$active,patches:$patches,not_upstream_commits:$not_upstream,integration_artifacts:$artifacts,retired_history_patches:$retired_patches,accepted_upstream_patches:$accepted_patches,trend:$trend,classes:{pending:$pending,"rejected-but-retained":$rejected,private:$private,superseded:$superseded}}, oldest_pending:{id:$oldest_pending,date:$oldest_pending_date,age_days:$oldest_pending_age}, last_upstream_merge:{touched:$touched}, accepted_upstream:$accepted, signals:$signals, errors:$errors, healthy:($errors|length == 0 and $superseded == 0 and $trend != "up")}'
else
  printf 'Fork divergence health: retained=%s patches=%s not-upstream=%s integration-artifacts=%s retired-history-patches=%s accepted-upstream-patches=%s trend=%s superseded=%s signals=%s errors=%s\n' \
    "$active_count" "$carried_patch_count" "$not_upstream_total" "$artifact_count" "$retired_patch_count" "$accepted_patch_count" "$trend" "$superseded_count" "$signal_count" "$error_count"
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
  printf 'Accepted upstream and retired: %s\n' "$accepted_record_count"
  while IFS=$'\t' read -r id topic summary date fork_patch upstream_patch patch_id; do
    [ -n "$id" ] || continue
    printf '%s [accepted-upstream] topic=%s retired=%s\n' "$id" "$topic" "$date"
    printf '  did: %s\n' "$summary"
    if grep -Fxq "$fork_patch" "$ACCEPTED"; then
      printf '  proof: fork patch %s equals upstream commit %s (patch-id %s)\n' "$fork_patch" "$upstream_patch" "$patch_id"
    else
      printf '  proof: unproved against %s and %s; see the mismatch below\n' "$ORIGIN_REF" "$UPSTREAM_REF"
    fi
  done < <(jq -r '.retired_upstream // [] | .[] | [.id,.topic,.summary,.date,.fork_patch,.upstream_patch,.patch_id] | @tsv' "$MANIFEST")
  if [ "$last_touched_count" -gt 0 ] && [ -n "$last_sync" ]; then
    fork_before=$(printf '%s' "$last_sync" | jq -r .fork_before)
    upstream_before=$(printf '%s' "$last_sync" | jq -r .upstream_before)
    upstream_after=$(printf '%s' "$last_sync" | jq -r .upstream_after)
    printf 'Relevance review: git -C %s range-diff --remerge-diff %s..%s %s..%s\n' \
      "$REPO" "$upstream_before" "$fork_before" "$upstream_after" "$ORIGIN_REF"
  fi
  if [ "$signal_count" -gt 0 ]; then
    printf 'Manifest/Git signals (informational):\n'
    sed 's/^/  - /' "$SIGNALS"
  fi
  if [ "$error_count" -gt 0 ]; then
    printf 'Health errors:\n'
    sed 's/^/  - /' "$ERRORS"
  fi
fi

[ "$error_count" -eq 0 ] && [ "$superseded_count" -eq 0 ] \
  && { [ "$FACTS_ONLY" -eq 1 ] || [ "$trend" != up ]; }
