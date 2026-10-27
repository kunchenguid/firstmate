#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change, exactly one degraded
# line for a ready change that degraded after its ready report (a failing
# check on GitHub, a failing head pipeline on GitLab), and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. A degraded line names the head or pipeline that degraded, the
# failed jobs with the forge's failure reasons, and the pipeline or check
# URL, so the wake says which test broke without a job-log dig; the watcher
# dedupes one wake per transition on that head/pipeline (bin/fm-watch.sh).
# The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and tea for Forgejo, so an upstream checkout
# needs no extra tooling to follow GitHub or GitLab. The Gerrit and Forgejo
# branches additionally need jq, and so does the GitLab degraded read (its
# rendered view carries no head pipeline state); without jq a GitLab poll
# still wakes on a merge from the plain state field. A GitLab poll also emits
# "ontrain" while the merge request has a merge-train car, and a degraded
# train=dropped line once the car is gone from a still-open merge request; the
# watcher wakes on a drop only after it saw the car on the train.
set -u
LC_ALL=C
export LC_ALL

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
# a doctored sidecar cannot silently address a different project or a differently
# spelled URL. The host is one of those components: a GitHub Enterprise host is
# recorded only by bin/fm-pr-lib.sh after this home named it in
# config/github-hosts, and it is re-checked for shape here like every other
# provider's, because this static body sources nothing and cannot read config.
case "$provider" in
  github)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
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
    [ "$url" = "https://$host/$owner/$repo/pull/$number" ] || exit 0
    # One read answers both questions this poll owns: the merged wake it has
    # always owned, and the degraded state firstmate now watches for. The
    # parse runs through gh's own --jq, so no JSON processor is needed here.
    # Any failing check on the rollup counts as degraded because gh's rollup
    # cannot say which checks are required: at the ready report the required
    # checks were green, so a failing one here is a change worth waking for.
    # The degraded line names every failing check with its conclusion and the
    # first one's URL, so the wake says which test broke without a job-log
    # dig. Every error, a non-open state, a pending or green rollup, and an
    # unreadable head all stay silent; only the exact line shape below leaves
    # this branch, and the head is validated here so the watcher's dedupe
    # marker never sees another byte.
    # shellcheck disable=SC2016  # The filter's $f and $r are jq variables, expanded by jq, not the shell.
    result=$(GH_HOST=$host gh pr view "$url" --json state,headRefOid,statusCheckRollup --jq '
      if .state == "MERGED" then
        "merged"
      elif .state == "OPEN"
        and ([.statusCheckRollup[]?
                | select((.conclusion // .state // "") as $r
                         | $r == "FAILURE" or $r == "TIMED_OUT"
                           or $r == "STARTUP_FAILURE" or $r == "ERROR")]
             | length) > 0
      then
        ([.statusCheckRollup[]?
            | select((.conclusion // .state // "") as $r
                     | $r == "FAILURE" or $r == "TIMED_OUT"
                       or $r == "STARTUP_FAILURE" or $r == "ERROR")]) as $f
        | ([$f[] | .detailsUrl // .targetUrl // ""] | .[0] // "") as $u
        | "degraded head=" + (.headRefOid // "")
          + " jobs=" + ([($f[]
              | ((.name // .context // "check") | gsub("[\\n\\r\\t]"; " "))
                + ":" + (((.conclusion // .state // "FAILURE"))
                          | gsub("[\\n\\r\\t]"; " ")))]
            | join(",") | .[:300])
          + (if $u == "" then "" else " url=" + ($u | gsub("[\\n\\r\\t]"; " ")) end)
      else
        ""
      end' 2>/dev/null) || exit 0
    case $result in
      merged)
        printf '%s\n' merged
        ;;
      'degraded head='*)
        case $result in
          *$'\n'*) exit 0 ;;
        esac
        head=${result#'degraded head='}
        head=${head%% *}
        case $head in
          ''|*[!0-9a-f]*) exit 0 ;;
        esac
        [ "${#head}" -eq 40 ] || exit 0
        [ "${#result}" -le 2000 ] || exit 0
        printf '%s\n' "$result"
        ;;
    esac
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
    # comes from the validated record rather than glab's configured default,
    # and GITLAB_HOST pins it the same way the merge path pins it. It cannot
    # take a merge request URL the way gh does: that form shells out to git
    # for the current repository, and the watcher runs in no repository.
    # The record is read as JSON through glab's own -F json, the same read the
    # merge path makes, because the rendered view carries no head pipeline
    # state. Only an exact "merged" wakes as a merge. A failing head pipeline
    # on a still-open merge request emits the degraded pipeline line, because
    # a merge train drops a merge request when its pipeline does not succeed.
    # Any other open merge request has its merge-train car read: a present car
    # emits "ontrain", an absent one (HTTP 404) emits a degraded train=dropped
    # line naming the merge request's detailed merge status, and the watcher
    # wakes only when it last saw the car on the train. Every error, a closed
    # merge request, a pending or green head pipeline, and an unreadable record
    # stay silent. Without jq the poll falls back to the plain state field,
    # which keeps the merged wake for a watch armed before jq was required.
    enc=${path//\//%2F}
    if ! command -v jq >/dev/null 2>&1; then
      raw=$(GITLAB_HOST=$host glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
      state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
      [ "$state" = merged ] && printf '%s\n' merged
      exit 0
    fi
    raw=$(GITLAB_HOST=$host glab mr view "$number" -R "https://$host/$path" -F json 2>/dev/null) || exit 0
    [ -n "$raw" ] || exit 0
    result=$(printf '%s' "$raw" | jq -r '
      if type == "object"
         and (.state | type) == "string"
         and ((.head_pipeline | type) == "object" or .head_pipeline == null)
      then
        if .state == "merged" then
          "merged"
        elif (.state == "opened" or .state == "locked")
             and (.head_pipeline | type) == "object"
             and (.head_pipeline.status | type) == "string"
             and .head_pipeline.status == "failed"
             and (.head_pipeline.id | type) == "number"
             and .head_pipeline.id > 0
        then
          "degraded pipeline=\(.head_pipeline.id)"
        elif .state == "opened" or .state == "locked" then
          "open \(.detailed_merge_status // "" | if type == "string" then . else "" end)"
        else
          ""
        end
      else
        error("invalid merge request record")
      end' 2>/dev/null) || exit 0
    case $result in
      open\ *)
        reason=${result#open }
        case $reason in
          *[!a-z_]*) reason= ;;
        esac
        car=$(GITLAB_HOST=$host glab api "projects/$enc/merge_trains/merge_requests/$number" 2>&1)
        car_rc=$?
        if [ "$car_rc" -eq 0 ]; then
          printf '%s' "$car" | jq -e 'type == "object" and (.id | type) == "number"' >/dev/null 2>&1 \
            && printf '%s\n' ontrain
        else
          case $car in
            *'(HTTP 404)'*)
              line="degraded train=dropped url=$url"
              [ -z "$reason" ] || line="$line reason=$reason"
              printf '%s\n' "$line"
              ;;
          esac
        fi
        exit 0
        ;;
    esac
    case $result in
      merged)
        printf '%s\n' merged
        ;;
      'degraded pipeline='*)
        case $result in
          *$'\n'*) exit 0 ;;
        esac
        pipeline=${result#'degraded pipeline='}
        case $pipeline in
          [1-9]*) ;;
          *) exit 0 ;;
        esac
        case $pipeline in
          *[!0-9]*) exit 0 ;;
        esac
        [ "${#pipeline}" -le 18 ] || exit 0
        # The degraded line names the failed jobs with their forge failure
        # reasons, following a failed bridge into its child pipeline so the
        # wake says which test broke without a job-log dig. Bounded depth and
        # seen-list keep one misbehaving pipeline graph from looping the
        # read, and every read failure simply shortens the detail: a fetch
        # failure can never be read as a change of state.
        detail=
        seen=
        frontier=$pipeline
        depth=0
        while [ -n "$frontier" ] && [ "$depth" -lt 3 ]; do
          next=
          for current in $frontier; do
            case " $seen " in *" $current "*) continue ;; esac
            seen="$seen $current "
            names=$(GITLAB_HOST=$host glab api "projects/$enc/pipelines/$current/jobs?per_page=100" 2>/dev/null \
              | jq -r 'if type == "array" then
                  [.[]
                    | select((.status // "") == "failed")
                    | ((.name // "job") | gsub("[\\n\\r\\t]"; " "))
                      + (if (.failure_reason // "") != ""
                         then ":" + ((.failure_reason // "") | gsub("[\\n\\r\\t]"; " "))
                         else ""
                         end)]
                  | join(",")
                else
                  ""
                end' 2>/dev/null) || names=
            [ -n "$names" ] && detail="$detail${detail:+,}$names"
            children=$(GITLAB_HOST=$host glab api "projects/$enc/pipelines/$current/bridges?per_page=100" 2>/dev/null \
              | jq -r 'if type == "array" then
                  [.[]
                    | select((.status // "") == "failed")
                    | select((.downstream_pipeline.id // 0) > 0)
                    | .downstream_pipeline.id | tostring]
                  | join(" ")
                else
                  ""
                end' 2>/dev/null) || children=
            [ -n "$children" ] && next="$next${next:+ }$children"
          done
          frontier=$next
          depth=$((depth + 1))
        done
        detail=$(printf '%s' "$detail" | head -c 300)
        case $detail in
          *$'\n'*) detail= ;;
        esac
        line="degraded pipeline=$pipeline url=https://$host/$path/-/pipelines/$pipeline"
        [ -z "$detail" ] || line="$line jobs=$detail"
        [ "${#line}" -le 2000 ] || exit 0
        printf '%s\n' "$line"
        ;;
    esac
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
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
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  forgejo)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    [ "$owner" != "$path" ] || exit 0
    for segment in "$owner" "$repo"; do
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || exit 0
      case "$segment" in
        .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    command -v tea >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    # tea addresses a repo by slug only; the host comes from a named login
    # rather than a URL the way gh and glab take one, so the login registered
    # for this exact host is resolved fresh on every poll rather than trusted
    # from anywhere durable. Refuse to guess when zero or more than one
    # registered login matches, rather than picking one arbitrarily.
    # The list is parsed as JSON, never split on quotes per line, so a login
    # printed as one compact object still matches; this is the same filter
    # bin/fm-pr-lib.sh's fm_pr_forgejo_login applies.
    login=$(
      tea login list --output json 2>/dev/null | jq -er --arg h "$host" '
        if type == "array" then
          [ .[]
            | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
                     and (.url | type) == "string")
            | select((.url
                      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                      | sub("[/?#].*$"; "")
                      | sub("^.*@"; "")
                      | sub(":[0-9]+$"; "")) == $h)
            | .name ]
          | if length == 1 then .[0] else error("not exactly one matching login") end
        else
          error("login list is not an array")
        end' 2>/dev/null
    ) || exit 0
    [ -n "$login" ] || exit 0
    # tea's single-PR view ignores field selection, so the one pull request
    # is read by number from the REST record through "tea api", which keeps
    # the credential inside tea. "tea api" exits 0 on an HTTP error with the
    # error body as output, so only a boolean merged field of true wakes this
    # poll and every other reading stays silent.
    merged=$(tea api --login "$login" --repo "$owner/$repo" \
      "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null | jq -r '
        if type == "object" and (.merged | type) == "boolean"
        then .merged | tostring
        else error("invalid pull request record")
        end' 2>/dev/null) || exit 0
    [ "$merged" = true ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
