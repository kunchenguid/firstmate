#!/usr/bin/env bash
# Durable, firstmate-private merge-provenance record: written only by the two
# recorded merge paths (bin/fm-pr-merge.sh and bin/fm-merge-local.sh) at the
# moment their own merge action succeeds, and read only by
# bin/fm-merge-attribution.sh. This is not "who merged it" - firstmate, every
# crewmate, and the captain share one forge identity, so no record can carry
# that - it is "did this merge go through the one path firstmate uses to
# merge." A merge with no matching record here was not made through that
# path, whatever its forge merged-by field says.
#
# Record layout, one field per line: version tag, task id, method
# (pr-github|pr-gitlab|local-only), provider (github|gitlab|empty for
# local-only), url (empty for local-only), the merged head commit, and a UTC
# timestamp. The embedded task id and method are revalidated on read so a
# record copied or aliased onto another task's path is refused rather than
# trusted. Callers must source bin/fm-pr-lib.sh first: this file reuses its
# task-id, head-commit, and private-file validation rather than restating them.
FM_MERGE_PROV_ID=
FM_MERGE_PROV_METHOD=
FM_MERGE_PROV_PROVIDER=
FM_MERGE_PROV_URL=
FM_MERGE_PROV_HEAD=
FM_MERGE_PROV_AT=

# fm_merge_default_branch <project-dir>: the single owner of default-branch
# resolution shared by bin/fm-merge-local.sh (which merges into it) and
# bin/fm-merge-attribution.sh (which reads its live tip for a local-only
# task's attribution check).
fm_merge_default_branch() {
  local proj=$1 ref branch
  ref=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# fm_merge_prov_write <state> <id> <method> <provider> <url> <head>
# Writes the record atomically (mktemp + chmod 0600 + mv) and overwrites any
# prior record for the same task, because only the most recent merge through
# the recorded path is ever meaningful. Callers treat a write failure as
# non-fatal to the merge itself: the merge already happened, and a lost
# provenance record degrades safely to unattributed rather than blocking or
# misreporting the merge outcome.
fm_merge_prov_write() {
  local state=$1 id=$2 method=$3 provider=$4 url=$5 head=$6
  local dest tmp device at
  fm_task_id_path_safe "$id" || return 1
  case "$method" in
    pr-github | pr-gitlab | local-only) ;;
    *) return 1 ;;
  esac
  fm_pr_head_valid "$head" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  dest="$state/$id.merge-provenance"
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-merge-prov.XXXXXX") || return 1
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! printf 'fm-merge-provenance-v1\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$id" "$method" "$provider" "$url" "$head" "$at" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$dest" 600 "$device"
}

# fm_merge_prov_read <state> <id>: populate FM_MERGE_PROV_* on success, refuse
# and clear them on any missing, malformed, symlinked, hard-linked, wrongly
# permissioned, or id-mismatched record.
fm_merge_prov_read() {
  local state=$1 id=$2 file device
  local version rec_id method provider url head at _extra
  FM_MERGE_PROV_ID=
  FM_MERGE_PROV_METHOD=
  FM_MERGE_PROV_PROVIDER=
  FM_MERGE_PROV_URL=
  FM_MERGE_PROV_HEAD=
  FM_MERGE_PROV_AT=
  fm_task_id_path_safe "$id" || return 1
  file="$state/$id.merge-provenance"
  [ -e "$file" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$file" 600 "$device" || return 1
  exec 6< "$file" || return 1
  IFS= read -r version <&6 || { exec 6<&-; return 1; }
  IFS= read -r rec_id <&6 || { exec 6<&-; return 1; }
  IFS= read -r method <&6 || { exec 6<&-; return 1; }
  IFS= read -r provider <&6 || { exec 6<&-; return 1; }
  IFS= read -r url <&6 || { exec 6<&-; return 1; }
  IFS= read -r head <&6 || { exec 6<&-; return 1; }
  IFS= read -r at <&6 || { exec 6<&-; return 1; }
  if IFS= read -r _extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$version" = fm-merge-provenance-v1 ] || return 1
  [ "$rec_id" = "$id" ] || return 1
  case "$method" in
    pr-github | pr-gitlab | local-only) ;;
    *) return 1 ;;
  esac
  fm_pr_head_valid "$head" || return 1
  # Consumed by bin/fm-merge-attribution.sh after this function returns.
  # shellcheck disable=SC2034
  FM_MERGE_PROV_ID=$rec_id
  # shellcheck disable=SC2034
  FM_MERGE_PROV_METHOD=$method
  # shellcheck disable=SC2034
  FM_MERGE_PROV_PROVIDER=$provider
  # shellcheck disable=SC2034
  FM_MERGE_PROV_URL=$url
  # shellcheck disable=SC2034
  FM_MERGE_PROV_HEAD=$head
  # shellcheck disable=SC2034
  FM_MERGE_PROV_AT=$at
}
