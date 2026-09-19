#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, and az with the azure-devops extension for Azure DevOps, so an
# upstream checkout needs no extra tooling to follow any of them.
set -u
LC_ALL=C
export LC_ALL

# Decode the percent-escapes an Azure DevOps project or repository segment
# carries, so the name compared against the forge is the real one. Every
# escape is already proved well formed before this runs, and the segment
# character set has no backslash, so "%b" sees only the "\xNN" it is given.
ado_decode() {  # <segment>
  printf -v ADO_DECODED '%b' "${1//%/\\x}"
}

# The character rules bin/fm-pr-lib.sh applies when a URL is armed, restated
# here because this program is byte-static and sources nothing.
ado_segment_valid() {  # <segment>
  local segment=$1 rest
  [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
  case "$segment" in
    _*|.*|*[!A-Za-z0-9._~%'()'-]*) return 1 ;;
  esac
  rest=$segment
  while [ "${rest#*%}" != "$rest" ]; do
    rest=${rest#*%}
    case "$rest" in
      00*) return 1 ;;
      [0-9A-Fa-f][0-9A-Fa-f]*) ;;
      *) return 1 ;;
    esac
  done
  ado_decode "$segment"
  [ "${#ADO_DECODED}" -ge 1 ] && [ "${#ADO_DECODED}" -le 255 ] || return 1
  case "$ADO_DECODED" in
    .|..|*/*|*\\*|*[[:cntrl:]]*|' '*|*' ') return 1 ;;
  esac
}

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  azuredevops)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 5 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # <org>/<project>/_git/<repo>, or <org>/_git/<repo> when the repository
    # carries its project's own name. The organisation is the first segment on
    # dev.azure.com and the collection on a server install.
    org=${path%%/*}
    rest=${path#*/}
    case "$rest" in
      _git/*)
        repo=${rest#_git/}
        [ "$rest" = "_git/$repo" ] || exit 0
        ;;
      *)
        project=${rest%%/*}
        repo=${rest#*/_git/}
        [ "$rest" = "$project/_git/$repo" ] || exit 0
        ado_segment_valid "$project" || exit 0
        ;;
    esac
    [ "${#org}" -ge 1 ] && [ "${#org}" -le 63 ] || exit 0
    case "$org" in
      -*|*-|*[!A-Za-z0-9-]*) exit 0 ;;
    esac
    ado_segment_valid "$repo" || exit 0
    expected_repo=$ADO_DECODED
    [ "$url" = "https://$host/$path/pullrequest/$number" ] || exit 0
    # az repos addresses one organisation and resolves the pull request by an
    # organisation-wide id, so the organisation URL comes from the validated
    # record and --detect false keeps az from reaching for a git repository
    # the watcher does not have. The query is a list, which az renders in
    # order one value per line, and a null renders as the literal "None"; only
    # a "completed" status with a real merge commit is the landed reading, so
    # an abandoned or still-active pull request, a changed output format, and
    # an unreadable pull request are all silent rather than a false merge.
    raw=$(az repos pr show --id "$number" --organization "https://$host/$org" \
      --detect false --only-show-errors --output tsv \
      --query "[status, repository.name, lastMergeCommit.commitId]" 2>/dev/null) || exit 0
    status=
    forge_repo=
    merge_commit=
    { IFS= read -r status; IFS= read -r forge_repo; IFS= read -r merge_commit; } <<EOF
$raw
EOF
    [ "$status" = completed ] || exit 0
    case "$merge_commit" in
      ''|*[!0-9a-f]*) exit 0 ;;
    esac
    [ "${#merge_commit}" -eq 40 ] || [ "${#merge_commit}" -eq 64 ] || exit 0
    # A pull request id is unique per organisation rather than per repository,
    # so az cannot be scoped to the repository the way glab is scoped by
    # project URL. Binding the answer to the repository the URL names is what
    # keeps an id that belongs to a different repository from being reported
    # as this pull request's merge. Azure DevOps treats those names
    # case-insensitively.
    [ -n "$forge_repo" ] || exit 0
    lc_expected=$(printf '%s' "$expected_repo" | tr '[:upper:]' '[:lower:]') || exit 0
    lc_forge=$(printf '%s' "$forge_repo" | tr '[:upper:]' '[:lower:]') || exit 0
    [ "$lc_expected" = "$lc_forge" ] || exit 0
    printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
