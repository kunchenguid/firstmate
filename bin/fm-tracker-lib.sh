#!/usr/bin/env bash
# fm-tracker-lib.sh - shared contract for firstmate's GitHub Issues project
# layer. Sourced by bin/fm-tracker.sh and bin/fm-tracker-notify.sh.
#
# This file owns the three things that must not drift between the writer, the
# reader, and the wake: the type-label vocabulary, the blocked-by edge format,
# and the guards that refuse a malformed or destructive operation.
#
# Not executable on its own.
#
# Constants and GraphQL documents here are consumed by the sourcing scripts,
# which shellcheck cannot see from this file alone.
# shellcheck disable=SC2034

# The complete type vocabulary. Type is carried by a label and never by the
# title, so rewording a title cannot reclassify a ticket.
FM_TRACKER_TYPES='destination decision unknown task'
FM_TRACKER_LABEL_PREFIX='fm:'

# The one heading blocking edges live under, and the one line shape allowed
# beneath it. GitHub builds a queryable trackedIssues edge only from a markdown
# task-list reference, so this shape is what makes a blocker visible to the
# frontier query at all. The checkbox is GitHub's to tick as the blocker closes.
FM_TRACKER_BLOCKED_HEADING='## Blocked by'
FM_TRACKER_EDGE_RE='^- \[[ xX]\] #[1-9][0-9]*$'

# Wording that means "this is blocked" in prose. A body carrying any of these
# outside the canonical section is refused: prose blockers read as authoritative
# to a human and are invisible to the query, which is how a genuinely blocked
# ticket came back READY.
FM_TRACKER_PROSE_RE='blocked[ -]?by|blocked on|blocks |depends on|dependent on|waiting on|waits on|blocker'

FM_TRACKER_WATCH_MAGIC='fm-tracker-watch-v1'
FM_TRACKER_CURSOR_MAGIC='fm-tracker-cursor-v1'
# One conditional request per repository plus one for /notifications must finish
# well inside FM_CHECK_TIMEOUT (30s by default), so the watch list is bounded.
FM_TRACKER_MAX_WATCHED_REPOS=10
# GitHub states its own cadence on /notifications via X-Poll-Interval. This is
# only the floor used when a response carries no such header.
FM_TRACKER_DEFAULT_POLL_INTERVAL=60

# ---------------------------------------------------------------------------
# Identity validation
# ---------------------------------------------------------------------------

fm_tracker_repo_parse() {  # <owner/repo>
  local spec=${1-} owner repo
  FM_TRACKER_OWNER=
  FM_TRACKER_REPO=
  case "$spec" in
    */*/*|/*|*/) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  owner=${spec%%/*}
  repo=${spec#*/}
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  [ "${#owner}" -le 39 ] && [ "${#repo}" -le 100 ] || return 1
  case "$owner" in
    *[!A-Za-z0-9-]*|-*|*-) return 1 ;;
  esac
  case "$repo" in
    *[!A-Za-z0-9._-]*|.|..) return 1 ;;
  esac
  FM_TRACKER_OWNER=$owner
  FM_TRACKER_REPO=$repo
}

fm_tracker_issue_number_valid() {  # <n>
  local n=${1-}
  case "$n" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
}

fm_tracker_blocker_csv_valid() {  # <csv>
  local csv=${1-} n
  [ -n "$csv" ] || return 1
  while IFS= read -r n; do
    fm_tracker_issue_number_valid "$n" || return 1
  done <<EOF
$(printf '%s' "$csv" | tr ',' '\n')
EOF
}

fm_tracker_type_valid() {  # <type>
  local t=${1-} known
  for known in $FM_TRACKER_TYPES; do
    [ "$t" = "$known" ] && return 0
  done
  return 1
}

fm_tracker_type_label() {  # <type>
  printf '%s%s\n' "$FM_TRACKER_LABEL_PREFIX" "$1"
}

fm_tracker_all_labels() {
  local t out=''
  for t in $FM_TRACKER_TYPES; do
    out="$out $(fm_tracker_type_label "$t")"
  done
  printf '%s\n' "${out# }"
}

# Read the type off a space-separated label list into FM_TRACKER_TYPE and
# FM_TRACKER_TYPE_COUNT. Two type labels is an ambiguity, and the count is what
# reports it, so both are needed and both are set here.
#
# These are globals rather than a printed value on purpose: a command
# substitution runs in a subshell, so a count assigned there would never reach
# the caller, and the caller would read a stale count from the previous ticket.
FM_TRACKER_TYPE=''
FM_TRACKER_TYPE_COUNT=0
fm_tracker_type_of_labels() {  # <labels>
  local labels=${1-} l
  FM_TRACKER_TYPE=''
  FM_TRACKER_TYPE_COUNT=0
  for l in $labels; do
    case "$l" in
      "$FM_TRACKER_LABEL_PREFIX"*)
        FM_TRACKER_TYPE=${l#"$FM_TRACKER_LABEL_PREFIX"}
        FM_TRACKER_TYPE_COUNT=$((FM_TRACKER_TYPE_COUNT + 1))
        ;;
    esac
  done
}

fm_tracker_labels_answerable() {  # <labels>
  fm_tracker_type_of_labels "${1-}"
  [ "$FM_TRACKER_TYPE_COUNT" -eq 1 ] || return 1
  [ "$FM_TRACKER_TYPE" = decision ] || [ "$FM_TRACKER_TYPE" = unknown ]
}

# ---------------------------------------------------------------------------
# Defect 1: prose blockers are refused, never accepted
# ---------------------------------------------------------------------------

# Report every prose blocking declaration in a body, one record per finding:
#
#     <lineno>\x1f<the offending line>\x1f<space-separated issue numbers it names>
#
# A blocking declaration is a BLOCK, not a line: a heading such as
# "**Blocked by:**" followed by task-list references is one declaration, and its
# references belong to it even though they sit on later lines. Judging the
# heading alone would report "names no issue" about a block that plainly names
# one, which is the same confident wrong answer this whole guard exists to stop.
#
# A finding is raised when a line reads as a blocking statement outside the
# canonical section, or when a line inside the canonical section is neither
# blank nor the exact edge shape. Silent when the body is clean.
fm_tracker_body_prose_blockers() {  # <body>
  local body=${1-} lines=() line i n refs in_section=0 sep=$'\037'
  while IFS= read -r line; do
    lines+=("$line")
  done <<EOF
$body
EOF
  n=${#lines[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    line=${lines[$i]}
    if [ "$line" = "$FM_TRACKER_BLOCKED_HEADING" ]; then
      in_section=1
      i=$((i + 1))
      continue
    fi
    case "$line" in
      '#'*) in_section=0 ;;
    esac
    if [ "$in_section" -eq 1 ]; then
      # Inside the canonical section only the exact edge shape and blank lines
      # are allowed; anything else there is prose wearing the right heading.
      if [ -z "$line" ] || printf '%s' "$line" | grep -Eq "$FM_TRACKER_EDGE_RE"; then
        i=$((i + 1))
        continue
      fi
      printf '%s%s%s%s%s\n' "$((i + 1))" "$sep" "$line" "$sep" \
        "$(printf '%s' "$line" | grep -oE '#[0-9]+' | tr -d '#' | tr '\n' ' ')"
      i=$((i + 1))
      continue
    fi
    if printf '%s' "$line" | grep -Eiq "$FM_TRACKER_PROSE_RE"; then
      # Absorb the contiguous run of task-list references this declaration owns.
      refs=$(printf '%s' "$line" | grep -oE '#[0-9]+' | tr -d '#' | tr '\n' ' ')
      i=$((i + 1))
      while [ "$i" -lt "$n" ] && printf '%s' "${lines[$i]}" | grep -Eq "$FM_TRACKER_EDGE_RE"; do
        refs="$refs$(printf '%s' "${lines[$i]}" | grep -oE '#[0-9]+' | tr -d '#') "
        i=$((i + 1))
      done
      printf '%s%s%s%s%s\n' "$((i))" "$sep" "$line" "$sep" "$refs"
      continue
    fi
    i=$((i + 1))
  done
}

# Refuse a body carrying a prose blocker, naming every offending line and the
# supported alternative. Returns 1 so no caller can proceed to a write.
fm_tracker_body_prose_blocker_refuse() {  # <body>
  local found
  found=$(fm_tracker_body_prose_blockers "${1-}")
  [ -n "$found" ] || return 0
  printf 'error: refusing a prose blocking edge\n' >&2
  printf '%s\n' "$found" | while IFS=$'\037' read -r lineno text _refs; do
    printf '  line %s: %s\n' "$lineno" "$text" >&2
  done
  printf 'GitHub builds a queryable blocking edge only from a task-list reference,\n' >&2
  printf 'so a prose blocker is invisible to the frontier query and the ticket\n' >&2
  printf 'reports READY while it is genuinely blocked.\n' >&2
  printf 'Pass blockers as --blocked-by <n[,n...]> and let this script write them.\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Destructive-path guards
# ---------------------------------------------------------------------------
#
# A destructive path is never assembled from unguarded variables. An empty state
# root turns "$STATE/$id.check.sh" into "/<id>.check.sh"; an empty id turns it
# into a file nobody named. Both are refused here, before any caller can act on
# the result. The guards assert the facts that make a path ours to remove - the
# root is a real directory, the id is path-safe, the artifact is a plain file
# directly inside that root - rather than trusting the shape of the string.

fm_tracker_state_root_valid() {  # <state>
  local state=${1-}
  [ -n "$state" ] || return 1
  case "$state" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$state" ] && [ ! -L "$state" ]
}

# Resolve one artifact path for a task, or refuse. The suffix comes from a fixed
# allowlist of the artifacts this script publishes, so no caller can aim the
# guard at an arbitrary name.
fm_tracker_artifact_path() {  # <state> <task> <suffix>
  local state=${1-} task=${2-} suffix=${3-} parent
  FM_TRACKER_ARTIFACT=
  fm_tracker_state_root_valid "$state" || return 1
  fm_pr_task_id_valid "$task" || return 1
  case "$suffix" in
    .check.sh|.check-trust|.tracker-watch|.tracker-cursor) ;;
    *) return 1 ;;
  esac
  # The composed path must sit directly inside the physical state directory, so
  # no component can walk out of it.
  parent=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  [ -n "$parent" ] || return 1
  FM_TRACKER_ARTIFACT="$parent/$task$suffix"
}

# True when the file is a plain, single-link, non-symlink file - the shape this
# script publishes and the only shape it will remove.
fm_tracker_plain_file() {  # <path>
  local path=${1-}
  [ -n "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ]
}

# True when the sidecar exists and declares itself one of ours.
fm_tracker_watch_armed() {  # <state> <task>
  local first
  fm_tracker_artifact_path "${1-}" "${2-}" .tracker-watch || return 1
  fm_tracker_plain_file "$FM_TRACKER_ARTIFACT" || return 1
  IFS= read -r first < "$FM_TRACKER_ARTIFACT" 2>/dev/null || return 1
  [ "$first" = "$FM_TRACKER_WATCH_MAGIC" ]
}

# Remove one artifact, refusing anything that is not the plain file this script
# published at that exact path. An absent artifact is success: removal is
# idempotent, but it is never blind.
fm_tracker_remove_artifact() {  # <state> <task> <suffix>
  fm_tracker_artifact_path "${1-}" "${2-}" "${3-}" || return 1
  [ -e "$FM_TRACKER_ARTIFACT" ] || [ -L "$FM_TRACKER_ARTIFACT" ] || return 0
  fm_tracker_plain_file "$FM_TRACKER_ARTIFACT" || return 1
  rm -f -- "$FM_TRACKER_ARTIFACT"
}

# ---------------------------------------------------------------------------
# The watcher shim
# ---------------------------------------------------------------------------

# The watcher copies a custom check to a randomly named snapshot before running
# it, so the check cannot derive its own task from $0 the way the PR poll does.
# The task id is passed as an argument instead, shell-quoted, and it has already
# passed fm_pr_task_id_valid before reaching here.
fm_tracker_shim_content() {  # <home> <root> <task>
  local home=$1 root=$2 task=$3
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-tracker.sh - GitHub issue-comment wake shim.' \
    '# The watcher runs this each check cycle; output becomes a check: wake.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-tracker-notify.sh") --task $(printf '%q' "$task")"
}

fm_tracker_shim_matches() {  # <file> <home> <root> <task>
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  cmp -s "$file" <(fm_tracker_shim_content "$2" "$3" "$4")
}

# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------

fm_tracker_destination_template() {
  cat <<'EOF'
## Destination

_What "done" looks like, in the captain's own words._

## Explicitly out of scope

_What this project is deliberately NOT doing, so scope creep has a named edge._

## Known unknowns

_What is not yet known. Each one that could change what gets built becomes its
own `fm:unknown` ticket._

## Checkable / watchable

**Checkable** - can be asserted by a test or a query, and belongs to the crew:

**Watchable** - only a human judgement settles it, and stays with the captain:
EOF
}

fm_tracker_answer_comment() {  # <decision> <settles> <not-settles>
  local decision=$1 settles=${2-} not_settles=${3-}
  printf '%s\n\n' '**Captain'"'"'s decision** (recorded verbatim):'
  printf '%s\n\n' "$decision"
  printf '%s\n' '**What this settles:**'
  if [ -n "$settles" ]; then
    printf '%s\n\n' "$settles"
  else
    printf '%s\n\n' '_Not stated. Read the decision above as settling only its own question._'
  fi
  printf '%s\n' '**What this does NOT settle:**'
  if [ -n "$not_settles" ]; then
    printf '%s\n' "$not_settles"
  else
    printf '%s\n' '_Not stated. Anything this decision does not name is still open._'
  fi
}

# ---------------------------------------------------------------------------
# The issue graph: one query, one record format
# ---------------------------------------------------------------------------

# Native sub-issue attachment, so hierarchy and its completion rollup come from
# GitHub rather than from a convention this script would have to re-derive.
# shellcheck disable=SC2016 # $name is a GraphQL variable, not a shell one.
FM_TRACKER_ADD_SUB_ISSUE='mutation($parentId:ID!,$subIssueId:ID!){
  addSubIssue(input:{issueId:$parentId,subIssueId:$subIssueId}){ subIssue{ number } }
}'

# shellcheck disable=SC2016 # $name is a GraphQL variable, not a shell one.
FM_TRACKER_GRAPH_QUERY='query($owner:String!,$repo:String!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    issues(first:100,after:$endCursor,states:[OPEN,CLOSED],orderBy:{field:CREATED_AT,direction:ASC}){
      pageInfo{hasNextPage endCursor}
      nodes{
        number state title body
        labels(first:20){nodes{name}}
        assignees(first:10){nodes{login}}
        parent{number}
        trackedIssues(first:50){
          nodes{
            number state title
            labels(first:20){nodes{name}}
            assignees(first:10){nodes{login}}
          }
        }
      }
    }
  }
}'

# One record per issue, fields separated by US (0x1f). Tab is deliberately NOT
# the separator: shell IFS treats whitespace delimiters as a run, so consecutive
# tabs would collapse and every field after an empty one would shift by one.
# 0x1f is not whitespace, so an empty field stays an empty field.
#
# Title and body are base64 so a multi-line body cannot break a record.
#   number  state  labels  assignees  parent  blockers  title_b64  body_b64
# where each blocker is "number|state|type|assignee" and blockers are comma
# separated.
FM_TRACKER_GRAPH_JQ='.data.repository.issues.nodes[]
| [ (.number|tostring),
    .state,
    ([.labels.nodes[].name]|join(" ")),
    ([.assignees.nodes[].login]|join(" ")),
    (if .parent then (.parent.number|tostring) else "-" end),
    ([.trackedIssues.nodes[]
      | [ (.number|tostring),
          .state,
          (([.labels.nodes[].name]|map(select(startswith("fm:")))|.[0]) // "fm:-" | ltrimstr("fm:")),
          ([.assignees.nodes[].login]|join(";"))
        ]|join("|")
     ]|join(",")),
    (.title|@base64),
    ((.body // "")|@base64)
  ]|join("\u001f")'

fm_tracker_b64_decode() {  # <b64>
  printf '%s' "$1" | base64 --decode 2>/dev/null
}

# Describe what one blocker is waiting on, in the captain's nouns rather than
# the graph's.
fm_tracker_blocker_phrase() {  # <number> <state> <type> <assignee>
  local n=$1 state=$2 type=$3 who=$4 what
  case "$type" in
    decision) what='a decision the captain owns' ;;
    unknown) what='an unresolved unknown' ;;
    task) what='unfinished work' ;;
    destination) what='the destination itself' ;;
    *) what='an untyped ticket' ;;
  esac
  if [ -n "$who" ]; then
    printf '#%s - %s, claimed by %s\n' "$n" "$what" "${who//;/, }"
  else
    printf '#%s - %s, unclaimed\n' "$n" "$what"
  fi
  : "$state"
}

# Render the frontier from graph records on stdin. Assigned tickets are excluded
# from both the ready and the blocked set: assignment IS the claim, so a claimed
# ticket is not available work.
fm_tracker_render_frontier() {  # <owner/repo>
  local slug=$1
  local number state labels assignees parent blockers title_b64 body_b64
  local title type ready='' blocked='' claimed='' b bn bstate btype bwho waits
  while IFS=$'\037' read -r number state labels assignees parent blockers title_b64 body_b64; do
    [ -n "$number" ] || continue
    [ "$state" = OPEN ] || continue
    title=$(fm_tracker_b64_decode "$title_b64")
    fm_tracker_type_of_labels "$labels"
    type=$FM_TRACKER_TYPE
    [ -n "$type" ] || type='untyped'
    if [ -n "$assignees" ]; then
      claimed="$claimed$(printf '  #%-5s [%-11s] %s\n            claimed by %s\n' \
        "$number" "$type" "$title" "${assignees// /, }")"
      continue
    fi
    waits=
    if [ -n "$blockers" ]; then
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        IFS='|' read -r bn bstate btype bwho <<EOF
$b
EOF
        [ "$bstate" = OPEN ] || continue
        waits="$waits$(printf '            waits on %s' "$(fm_tracker_blocker_phrase "$bn" "$bstate" "$btype" "$bwho")")
"
      done <<EOF
$(printf '%s' "$blockers" | tr ',' '\n')
EOF
    fi
    if [ -n "$waits" ]; then
      blocked="$blocked$(printf '  #%-5s [%-11s] %s\n' "$number" "$type" "$title")
$waits"
    else
      ready="$ready$(printf '  #%-5s [%-11s] %s\n' "$number" "$type" "$title")
"
    fi
    : "$parent" "$body_b64"
  done
  printf 'frontier: %s\n\n' "$slug"
  printf 'READY (open, unclaimed, no open blocker):\n'
  if [ -n "$ready" ]; then printf '%s' "$ready"; else printf '  (none)\n'; fi
  printf '\nBLOCKED (open, unclaimed, waiting on something):\n'
  if [ -n "$blocked" ]; then printf '%s' "$blocked"; else printf '  (none)\n'; fi
  printf '\nCLAIMED (excluded from the frontier - assignment is the claim):\n'
  if [ -n "$claimed" ]; then printf '%s' "$claimed"; else printf '  (none)\n'; fi
}

# Report every structurally malformed ticket. This is the standing guard against
# both observed defects returning by hand-editing.
fm_tracker_render_validate() {  # <owner/repo>
  local slug=$1
  local number state labels assignees parent blockers title_b64 body_b64
  local title body type problems=0 prose lineno text refs ref edges
  printf 'validate: %s\n' "$slug"
  while IFS=$'\037' read -r number state labels assignees parent blockers title_b64 body_b64; do
    [ -n "$number" ] || continue
    title=$(fm_tracker_b64_decode "$title_b64")
    body=$(fm_tracker_b64_decode "$body_b64")
    fm_tracker_type_of_labels "$labels"
    type=$FM_TRACKER_TYPE
    if [ "$FM_TRACKER_TYPE_COUNT" -eq 0 ]; then
      printf '  #%s missing type label - type would have to be guessed from the title: %s\n' "$number" "$title"
      problems=$((problems + 1))
    elif [ "$FM_TRACKER_TYPE_COUNT" -gt 1 ]; then
      printf '  #%s carries %s type labels (%s) - type is ambiguous\n' "$number" "$FM_TRACKER_TYPE_COUNT" "$labels"
      problems=$((problems + 1))
    fi
    # A prose blocker line is judged against the edges GitHub actually resolved,
    # never against how the line looks. A bold "**Blocked by:**" heading over a
    # real task-list reference still produces a queryable edge, and calling that
    # invisible would be the same confident wrong answer this guard exists to
    # catch. Only a reference with no matching edge is genuinely invisible.
    edges=" $(printf '%s' "$blockers" | tr ',' '\n' | cut -d'|' -f1 | tr '\n' ' ') "
    prose=$(fm_tracker_body_prose_blockers "$body")
    if [ -n "$prose" ]; then
      while IFS=$'\037' read -r lineno text refs; do
        if [ -z "${refs// /}" ]; then
          printf '  #%s line %s states a blocker in prose but names no issue - a human reads it\n' \
            "$number" "$lineno"
          printf '        as authoritative and nothing queries it: %s\n' "$text"
          problems=$((problems + 1))
          continue
        fi
        for ref in $refs; do
          case $edges in
            *" $ref "*)
              printf '  #%s line %s uses a non-canonical blocked-by heading for #%s - the edge\n' \
                "$number" "$lineno" "$ref"
              printf '        resolves, but this was not written by fm-tracker.sh add\n'
              ;;
            *)
              printf '  #%s line %s names #%s as a blocker with no resolved edge - invisible to\n' \
                "$number" "$lineno" "$ref"
              printf '        the frontier query, so this ticket reports READY while blocked\n'
              ;;
          esac
          problems=$((problems + 1))
        done
      done <<EOF
$prose
EOF
    fi
    if [ "$type" != destination ] && [ "$parent" = '-' ]; then
      printf '  #%s orphaned - no parent, so it hangs off no destination and never rolls up\n' "$number"
      problems=$((problems + 1))
    fi
    if [ "$type" = destination ] && [ "$parent" != '-' ]; then
      printf '  #%s is a destination but is attached under #%s - a destination is a root\n' "$number" "$parent"
      problems=$((problems + 1))
    fi
    : "$state" "$assignees"
  done
  if [ "$problems" -eq 0 ]; then
    printf '  no malformed tickets\n'
    return 0
  fi
  printf '\n%s malformed ticket(s). fm-tracker.sh add writes this structure correctly;\n' "$problems"
  printf 'hand-edits do not.\n'
  return 1
}

# After an answer closes a ticket, name every ticket whose last open blocker it
# was. Reading this from the graph rather than from the closing action keeps the
# answer honest: a ticket with another open blocker is not reported as freed.
fm_tracker_render_unblocked() {  # <closed-number>
  local closed=$1
  local number state labels assignees parent blockers title_b64 body_b64
  local title type b bn bstate btype bwho names='' still tracked
  while IFS=$'\037' read -r number state labels assignees parent blockers title_b64 body_b64; do
    [ -n "$number" ] || continue
    [ "$state" = OPEN ] || continue
    [ -n "$blockers" ] || continue
    tracked=0
    still=0
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      IFS='|' read -r bn bstate btype bwho <<EOF
$b
EOF
      [ "$bn" = "$closed" ] && tracked=1
      [ "$bstate" = OPEN ] && still=$((still + 1))
    done <<EOF
$(printf '%s' "$blockers" | tr ',' '\n')
EOF
    [ "$tracked" -eq 1 ] || continue
    title=$(fm_tracker_b64_decode "$title_b64")
    fm_tracker_type_of_labels "$labels"
    type=$FM_TRACKER_TYPE
    [ -n "$type" ] || type='untyped'
    if [ "$still" -eq 0 ]; then
      names="$names$(printf '  #%-5s [%-11s] %s\n' "$number" "$type" "$title")
"
    else
      names="$names$(printf '  #%-5s [%-11s] %s - still has %s open blocker(s)\n' \
        "$number" "$type" "$title" "$still")
"
    fi
    : "$assignees" "$parent" "$body_b64" "$btype" "$bwho"
  done
  if [ -n "$names" ]; then
    printf 'depended on #%s:\n%s' "$closed" "$names"
  else
    printf 'nothing was blocked on #%s\n' "$closed"
  fi
}
