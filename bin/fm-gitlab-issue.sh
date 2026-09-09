#!/usr/bin/env bash
# fm-gitlab-issue.sh - read and mutate one GitLab issue on firstmate's behalf,
# and map it to the local clone it belongs to.
#
# This is the single owner of how firstmate touches a GitLab issue: the later
# triage skill and the issue poller call these subcommands instead of composing
# `glab api` requests of their own. Every request targets the host parsed from
# the issue URL (`glab api --hostname`), never the current directory's remote,
# and every network call is bounded by FM_GITLAB_TIMEOUT seconds (default 30)
# through timeout, gtimeout, or a perl watchdog. Authentication stays inside
# glab; this script never reads, stores, or prints a token.
#
# Usage:
#   fm-gitlab-issue.sh show <issue-url> [--since <ISO-8601|epoch>]
#   fm-gitlab-issue.sh label <issue-url> <label> [--prefix <prefix>]
#   fm-gitlab-issue.sh comment <issue-url> --body-file <file>|-
#   fm-gitlab-issue.sh comment-update <issue-url> <note-id> --body-file <file>|-
#   fm-gitlab-issue.sh checklist <issue-url> <note-id> <n> --done <suffix>
#   fm-gitlab-issue.sh project <issue-url>
#   fm-gitlab-issue.sh --help
#
# <issue-url> is https://<host>/<group>[/<subgroup>...]/<project>/-/issues/<iid>.
# Nested subgroups are ordinary path segments; a trailing "#note_<id>" fragment
# is ignored. The host must be a plain lowercase DNS name (no port, no userinfo)
# and the project path is validated by bin/fm-pr-lib.sh's GitLab rules.
#
# Subcommands:
#   show    Print one JSON object: title, description, state, labels, author
#           ({id, username, name}), web_url, project_path_with_namespace,
#           project_id, iid, and notes. `notes` holds the non-system notes in
#           creation order from every page of the notes endpoint (glab
#           --paginate prints one array per page; they are folded into one
#           list), excluding notes written by the authenticated user itself
#           (read once per run from the `user` endpoint), each as
#           {id, author, created_at, body}. With --since only notes created
#           strictly after that instant are kept, compared at the precision
#           given (GitLab emits milliseconds); the value is an ISO-8601
#           timestamp (Z or numeric offset, optional fraction) or a Unix epoch.
#   label   Make <label> the only label carrying the prefix (default "fm::",
#           --prefix overrides): every other prefixed label is removed and the
#           new one added in a single PUT with add_labels/remove_labels. Labels
#           outside the prefix are never touched. A label that does not start
#           with the prefix is refused. Under the default "fm::" prefix the
#           label is validated further, against the closed set of issue states
#           owned by FM_LABEL_VOCABULARY below (that variable is the single
#           definition of those names; nothing else lists them); the refusal
#           names the whole set and happens before any request, so a typo can
#           never create a label as a side effect. A caller-supplied --prefix
#           is validated by prefix only, with no vocabulary check. Already-set
#           is a no-op. Prints "<label>\t<removed,labels>" (second field empty
#           when nothing was removed) and verifies the returned label set.
#   comment Create a note from <file> (or stdin with "-"). Prints
#           "<note-id>\t<issue-url>#note_<note-id>".
#   comment-update
#           Replace the body of note <note-id> from <file> or stdin. Prints
#           the same "<note-id>\t<note-url>" line. Keeping one plan or
#           checklist note current is done this way rather than with a new
#           progress comment.
#   checklist
#           In note <note-id>, turn the single line starting with "- [ ] <n>/"
#           into "- [x] <n>/..." and append " → <suffix>" to it, then update
#           the note. Refuses when no such line exists (including when the line
#           is already ticked) or when more than one line matches. Prints the
#           rewritten line.
#   project Map the issue to a local clone under $FM_HOME/projects/*/ by
#           comparing the URL's host and project path with each clone's
#           `git remote get-url origin`. An entry without a .git of its own is
#           skipped rather than resolved to an enclosing repository. Scheme,
#           userinfo, any port, a trailing
#           ".git", a trailing "/", and host and path case are normalised
#           away, so https, ssh://, and scp-like origins all match. Prints
#           "<clone-dir>\t<posture>" where <posture> is the exact output of
#           `bin/fm-project-mode.sh --raw <name>` ("<mode> <yolo>") or the word
#           "unregistered" when the clone has no data/projects.md line. Exits 3
#           when no clone matches, so the caller can route the issue to a
#           human with a registration reminder; exits 1 when two clones match.
#
# Environment:
#   FM_HOME              the operational home whose projects/ and data/ are read
#                        (default: this checkout, via FM_ROOT_OVERRIDE)
#   FM_PROJECTS_OVERRIDE clone root instead of $FM_HOME/projects
#   FM_GITLAB_TIMEOUT    seconds allowed per glab call (default 30)
#
# Hard limits: this script never closes or reopens an issue, never changes
# assignees or milestones, never writes a label outside the prefix, and posts a
# note only through comment and comment-update. Every refusal exits non-zero
# with one line on stderr.
#
# Exit codes: 0 success; 1 usage error or refusal; 2 glab or GitLab failure
# (including a timeout); 3 `project` found no matching clone.
#
# Requires glab and jq on PATH.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TIMEOUT="${FM_GITLAB_TIMEOUT:-30}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

usage() {
  sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

die() {  # <code> <message>
  printf 'fm-gitlab-issue: %s\n' "$2" >&2
  exit "$1"
}

case "${1:-}" in
  -h | --help | help) usage; exit 0 ;;
  '') usage >&2; exit 1 ;;
esac

SUB=$1
shift
case "$SUB" in
  show | label | comment | comment-update | checklist | project) ;;
  *) die 1 "unknown subcommand '$SUB' (see --help)" ;;
esac
[ $# -ge 1 ] || die 1 "$SUB needs an issue URL"
RAW_URL=$1
shift

# --- URL --------------------------------------------------------------------

ISSUE_HOST=
ISSUE_PATH=
ISSUE_IID=
parse_issue_url() {  # <url>
  local raw=${1-} pattern host path iid
  local LC_ALL=C
  raw=${raw%%#*}
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/issues/"; any earlier separator lands inside the captured path, where
  # fm_pr_gitlab_path_valid refuses the reserved "-" segment.
  pattern='^https://([A-Za-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/issues/([1-9][0-9]*)/?$'
  [[ "$raw" =~ $pattern ]] || return 1
  path=${BASH_REMATCH[2]}
  iid=${BASH_REMATCH[3]}
  host=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  fm_pr_gitlab_host_valid "$host" || return 1
  fm_pr_gitlab_path_valid "$path" || return 1
  ISSUE_HOST=$host
  ISSUE_PATH=$path
  ISSUE_IID=$iid
}

parse_issue_url "$RAW_URL" || die 1 "not a GitLab issue URL (expected https://<host>/<group>/<project>/-/issues/<iid>): $RAW_URL"
ISSUE_URL="https://$ISSUE_HOST/$ISSUE_PATH/-/issues/$ISSUE_IID"
# The validated path holds only [A-Za-z0-9._-] and "/", so encoding the
# separator is the whole of GitLab's required project-path encoding.
PROJECT_ENC=${ISSUE_PATH//\//%2F}
ISSUE_API="projects/$PROJECT_ENC/issues/$ISSUE_IID"

# --- glab -------------------------------------------------------------------

# glab_api <method> <endpoint> [<body-file>] [extra glab flags...]
# One bounded request against the issue's host. A body file is sent verbatim
# with --input and an explicit JSON Content-Type (glab sets none for --input),
# so a note body is never reinterpreted by glab's typed --field parsing.
# Response JSON is printed on stdout; any failure exits 2 with glab's own
# diagnostic (which never contains the token).
glab_api() {
  local method=$1 endpoint=$2 body=${3:-}
  shift 2
  [ $# -eq 0 ] || shift
  local -a cmd=(glab api --hostname "$ISSUE_HOST" --method "$method")
  [ -z "$body" ] || cmd+=(--input "$body" --header 'Content-Type: application/json')
  cmd+=("$@" "$endpoint")
  local out rc=0
  out=$(bounded "${cmd[@]}") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      124 | 137) die 2 "$method $endpoint timed out after ${TIMEOUT}s" ;;
      *) die 2 "$method $endpoint failed (glab exit $rc)" ;;
    esac
  fi
  printf '%s\n' "$out"
}

# bounded <command...>: run under the configured bound, TERM at the bound and
# KILL after one further bound, through whichever bounding tool this host has.
bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k "$TIMEOUT" "$TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k "$TIMEOUT" "$TIMEOUT" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX=WNOHANG -e '
      my $bound = shift;
      exit 127 unless defined $bound && $bound =~ /\A[0-9]+\z/;
      my $pid = fork;
      exit 127 unless defined $pid;
      if ($pid == 0) { exec @ARGV; exit 127 }
      my $step = 0.05;
      my $elapsed = 0;
      while (1) {
        my $done = waitpid $pid, WNOHANG;
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8) if $done == $pid;
        exit 127 if $done == -1;
        if ($elapsed >= $bound) {
          kill "TERM", $pid;
          my $grace = 0;
          my $gone = waitpid $pid, WNOHANG;
          while ($gone == 0 && $grace < $bound) {
            select undef, undef, undef, $step;
            $grace += $step;
            $gone = waitpid $pid, WNOHANG;
          }
          kill "KILL", $pid if $gone == 0;
          waitpid $pid, 0;
          exit 124;
        }
        select undef, undef, undef, $step;
        $elapsed += $step;
      }
    ' -- "$TIMEOUT" "$@"
  else
    return 127
  fi
}

require_tools() {
  local missing=
  command -v glab >/dev/null 2>&1 || missing=glab
  command -v jq >/dev/null 2>&1 || missing="${missing:+$missing and }jq"
  [ -z "$missing" ] || die 1 "$SUB requires $missing on PATH"
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
    || command -v perl >/dev/null 2>&1 \
    || die 1 "$SUB cannot bound glab within ${TIMEOUT}s: none of timeout, gtimeout, or perl is on PATH"
  case "$TIMEOUT" in
    '' | *[!0-9]* | 0) die 1 "FM_GITLAB_TIMEOUT must be a positive integer number of seconds" ;;
  esac
}

# json_field <json> <jq-filter>: one -r extraction, failing closed on a
# response that is not the JSON shape the endpoint documents.
json_field() {
  local value
  value=$(printf '%s\n' "$1" | jq -er "$2" 2>/dev/null) \
    || die 2 "unexpected GitLab response: missing $2"
  printf '%s\n' "$value"
}

WORK=
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT
workdir() {
  [ -n "$WORK" ] || WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-gitlab-issue.XXXXXX")
}

# body_to_file <file>|- <dest>: materialise a note body so --input reads a
# regular file whether the caller passed a path or stdin.
body_to_file() {
  local src=$1 dest=$2
  if [ "$src" = - ]; then
    cat > "$dest"
  else
    [ -f "$src" ] || die 1 "body file not found: $src"
    cat -- "$src" > "$dest"
  fi
  [ -s "$dest" ] || die 1 "refusing to post an empty note body"
}

note_id_valid() {
  case "${1-}" in
    '' | *[!0-9]* | 0*) return 1 ;;
  esac
}

note_url() {  # <note-id>
  printf '%s#note_%s\n' "$ISSUE_URL" "$1"
}

# --- show -------------------------------------------------------------------

cmd_show() {
  local since='' issue notes me since_json
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die 1 "--since needs a value"; since=$2; shift 2 ;;
      *) die 1 "show: unexpected argument '$1'" ;;
    esac
  done
  require_tools
  case "$since" in
    '') since_json=null ;;
    *[!0-9]*) since_json=$(jq -cn --arg s "$since" '$s') ;;
    *) since_json=$since ;;
  esac
  issue=$(glab_api GET "$ISSUE_API")
  me=$(glab_api GET user)
  notes=$(glab_api GET "$ISSUE_API/notes?sort=asc&order_by=created_at" '' --paginate)
  # glab --paginate prints one JSON array per page back to back, so after
  # slurping, everything from the third document on is a page of notes; a
  # single page is the one-element case of the same fold.
  printf '%s\n%s\n%s\n' "$issue" "$me" "$notes" | jq -es --argjson since "$since_json" --arg path "$ISSUE_PATH" '
    def to_epoch:
      if type == "number" then .
      else (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
            // error("not an ISO-8601 timestamp: " + .)) as $p
        | (($p.d + "T" + $p.t + "Z") | fromdateiso8601)
          + (($p.f // "0") | tonumber)
          - (if ($p.z // "Z") == "Z" then 0
             else (($p.z[1:3] | tonumber) * 3600 + ($p.z[-2:] | tonumber) * 60)
                  * (if $p.z[0:1] == "-" then -1 else 1 end)
             end)
      end;
    .[0] as $issue | .[1] as $me | (.[2:] | add // []) as $notes
    | ($since | if . == null then null else to_epoch end) as $cut
    | {
        title: $issue.title,
        description: $issue.description,
        state: $issue.state,
        labels: $issue.labels,
        author: ($issue.author | {id, username, name}),
        web_url: $issue.web_url,
        project_path_with_namespace: (($issue.references.full // ($path + "#")) | split("#")[0]),
        project_id: $issue.project_id,
        iid: $issue.iid,
        notes: [ $notes[]
          | select(.system == false)
          | select(.author.id != $me.id)
          | select($cut == null or (.created_at | to_epoch) > $cut)
          | {id, author: (.author | {id, username, name}), created_at, body} ]
      }
  ' 2>/dev/null || die 1 "show: could not assemble the issue (bad --since value or unexpected GitLab response)"
}

# --- label ------------------------------------------------------------------

# The default prefix and the closed set of states that live under it. This is
# the only definition of those names in the repository: the refusal below
# prints the set verbatim, so a caller (and the test suite) learns the
# vocabulary from the script rather than from a second copy of the list.
FM_LABEL_PREFIX='fm::'
FM_LABEL_VOCABULARY='fm::todo fm::triage fm::plan-review fm::accepted fm::needs-human fm::done fm::human-replied'

cmd_label() {
  local prefix="$FM_LABEL_PREFIX" new='' issue state removed body after
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || die 1 "--prefix needs a value"; prefix=$2; shift 2 ;;
      -*) die 1 "label: unexpected option '$1'" ;;
      *) [ -z "$new" ] || die 1 "label: exactly one label is expected"; new=$1; shift ;;
    esac
  done
  [ -n "$new" ] || die 1 "label needs the label to set"
  [ -n "$prefix" ] || die 1 "label: --prefix must not be empty"
  case "$new" in
    "$prefix"*) ;;
    *) die 1 "refusing label '$new': it does not start with the prefix '$prefix'" ;;
  esac
  case "$new" in
    "$prefix" | *,* | *[[:cntrl:]]*) die 1 "refusing malformed label '$new'" ;;
  esac
  if [ "$prefix" = "$FM_LABEL_PREFIX" ]; then
    case " $FM_LABEL_VOCABULARY " in
      *" $new "*) ;;
      *) die 1 "refusing label '$new': not a $FM_LABEL_PREFIX issue state; expected one of: $FM_LABEL_VOCABULARY" ;;
    esac
  fi
  require_tools
  issue=$(glab_api GET "$ISSUE_API")
  state=$(printf '%s\n' "$issue" | jq -ec --arg p "$prefix" --arg new "$new" '
    (.labels // []) | {
      removed: [ .[] | strings | select(startswith($p) and . != $new) ],
      has_new: (index($new) != null) }' 2>/dev/null) \
    || die 2 "unexpected GitLab response: no labels array on the issue"
  removed=$(printf '%s\n' "$state" | jq -c .removed)
  if [ "$removed" = '[]' ] && [ "$(printf '%s\n' "$state" | jq -r .has_new)" = true ]; then
    printf '%s\t\n' "$new"
    return 0
  fi
  workdir
  body="$WORK/label.json"
  jq -cn --arg new "$new" --argjson removed "$removed" \
    '{add_labels: $new} + (if ($removed | length) > 0 then {remove_labels: ($removed | join(","))} else {} end)' \
    > "$body"
  after=$(glab_api PUT "$ISSUE_API" "$body")
  printf '%s\n' "$after" | jq -e --arg new "$new" --argjson removed "$removed" \
    '.labels | index($new) != null and (map(select(. as $l | $removed | index($l))) | length == 0)' \
    >/dev/null 2>&1 || die 2 "label: GitLab did not return '$new' as the only '$prefix' label"
  printf '%s\t%s\n' "$new" "$(printf '%s\n' "$removed" | jq -r 'join(",")')"
}

# --- comment / comment-update -----------------------------------------------

# note_write <method> <endpoint> <body-source>: send {body: <file contents>}.
note_write() {
  local method=$1 endpoint=$2 src=$3 raw id
  workdir
  body_to_file "$src" "$WORK/note.body"
  jq -n --rawfile body "$WORK/note.body" '{body: $body}' > "$WORK/note.json"
  raw=$(glab_api "$method" "$endpoint" "$WORK/note.json")
  id=$(json_field "$raw" '.id | select(type == "number")')
  printf '%s\t%s\n' "$id" "$(note_url "$id")"
}

parse_body_file() {  # sets BODY_SRC from "--body-file <x>"
  BODY_SRC=
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) [ $# -ge 2 ] || die 1 "--body-file needs a path or -"; BODY_SRC=$2; shift 2 ;;
      *) die 1 "$SUB: unexpected argument '$1'" ;;
    esac
  done
  [ -n "$BODY_SRC" ] || die 1 "$SUB needs --body-file <file>|-"
}

cmd_comment() {
  parse_body_file "$@"
  require_tools
  note_write POST "$ISSUE_API/notes" "$BODY_SRC"
}

cmd_comment_update() {
  local note=${1:-}
  [ $# -ge 1 ] || die 1 "comment-update needs a note id"
  shift
  note_id_valid "$note" || die 1 "not a note id: '$note'"
  parse_body_file "$@"
  require_tools
  note_write PUT "$ISSUE_API/notes/$note" "$BODY_SRC"
}

# --- checklist --------------------------------------------------------------

cmd_checklist() {
  local note=${1:-} n=${2:-} suffix='' raw matches line
  [ $# -ge 2 ] || die 1 "checklist needs <note-id> <n> --done <suffix>"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --done) [ $# -ge 2 ] || die 1 "--done needs a suffix"; suffix=$2; shift 2 ;;
      *) die 1 "checklist: unexpected argument '$1'" ;;
    esac
  done
  note_id_valid "$note" || die 1 "not a note id: '$note'"
  case "$n" in
    '' | *[!0-9]* | 0*) die 1 "not a checklist item number: '$n'" ;;
  esac
  [ -n "$suffix" ] || die 1 "checklist needs --done <suffix>"
  case "$suffix" in
    *$'\n'* | *$'\r'*) die 1 "checklist: --done suffix must be a single line" ;;
  esac
  require_tools
  raw=$(glab_api GET "$ISSUE_API/notes/$note")
  workdir
  printf '%s\n' "$raw" | jq -er '.body | select(type == "string")' > "$WORK/old.body" 2>/dev/null \
    || die 2 "unexpected GitLab response: note $note has no body"
  matches=$(jq -Rsr --arg n "$n" '
    split("\n") | map(select(startswith("- [ ] " + $n + "/"))) | length' "$WORK/old.body")
  if [ "$matches" -eq 0 ]; then
    if jq -Rse --arg n "$n" 'split("\n") | any(startswith("- [x] " + $n + "/"))' "$WORK/old.body" >/dev/null; then
      die 1 "checklist item $n/ in note $note is already ticked"
    fi
    die 1 "note $note has no line starting with '- [ ] $n/'"
  fi
  [ "$matches" -eq 1 ] || die 1 "note $note has $matches lines starting with '- [ ] $n/'; refusing to guess"
  # The rewritten body keeps every other byte, including a CRLF line ending on
  # the edited line, and drops only the trailing newline jq -Rs read in.
  jq -Rsj --arg n "$n" --arg suffix "$suffix" '
    (if endswith("\n") then .[:-1] else . end)
    | split("\n")
    | map(if startswith("- [ ] " + $n + "/") then
            (if endswith("\r") then .[:-1] else . end) as $l
            | ("- [x] " + $l[6:] + " → " + $suffix + (if endswith("\r") then "\r" else "" end))
          else . end)
    | join("\n")' "$WORK/old.body" > "$WORK/new.body"
  line=$(jq -Rsr --arg n "$n" 'split("\n") | map(select(startswith("- [x] " + $n + "/"))) | .[0]' "$WORK/new.body")
  jq -n --rawfile body "$WORK/new.body" '{body: $body}' > "$WORK/note.json"
  glab_api PUT "$ISSUE_API/notes/$note" "$WORK/note.json" >/dev/null
  printf '%s\n' "$line"
}

# --- project ----------------------------------------------------------------

# origin_identity <origin-url>: print "host/path" for a remote origin with the
# scheme, userinfo, port, trailing ".git", trailing "/", and case normalised
# away, or return 1 for a local path, file:, or otherwise unmatchable origin.
origin_identity() {
  local url=$1 rest authority host path
  fm_project_origin_safe "$url" || return 1
  case $url in
    https://* | http://* | ssh://* | git://*)
      rest=${url#*://}
      authority=${rest%%/*}
      path=${rest#"$authority"}
      host=${authority##*@}
      case $host in
        '['*) return 1 ;;
      esac
      host=${host%%:*}
      ;;
    file://* | /*) return 1 ;;
    *)
      rest=$url
      case $url in
        *@*)
          case ${url%%@*} in
            *:*) ;;
            *) rest=${url#*@} ;;
          esac
          ;;
      esac
      case $rest in
        '['*) return 1 ;;
      esac
      host=${rest%%:*}
      path=${rest#*:}
      ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  [ -n "$host" ] && [ -n "$path" ] || return 1
  printf '%s/%s\n' "$host" "$path" | tr '[:upper:]' '[:lower:]'
}

cmd_project() {
  [ $# -eq 0 ] || die 1 "project: unexpected argument '$1'"
  [ -d "$PROJECTS" ] || die 3 "no clone matches $ISSUE_HOST/$ISSUE_PATH: no projects directory at $PROJECTS"
  local want clone origin identity name posture
  local -a matches=()
  want=$(printf '%s/%s' "$ISSUE_HOST" "$ISSUE_PATH" | tr '[:upper:]' '[:lower:]')
  for clone in "$PROJECTS"/*/; do
    clone=${clone%/}
    [ -d "$clone" ] && [ -e "$clone/.git" ] || continue
    origin=$(git -C "$clone" remote get-url origin 2>/dev/null) || continue
    identity=$(origin_identity "$origin") || continue
    [ "$identity" = "$want" ] || continue
    matches+=("$clone")
  done
  case ${#matches[@]} in
    0) die 3 "no clone under $PROJECTS has an origin matching $ISSUE_HOST/$ISSUE_PATH" ;;
    1) ;;
    *) die 1 "${#matches[@]} clones match $ISSUE_HOST/$ISSUE_PATH: ${matches[*]}" ;;
  esac
  clone=${matches[0]}
  name=$(basename "$clone")
  if [ -f "$DATA/projects.md" ] && awk -v n="$name" '$1 == "-" && $2 == n { found = 1; exit } END { exit !found }' "$DATA/projects.md"; then
    posture=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" --raw "$name" 2>/dev/null) \
      || die 1 "could not read the registered posture of $name"
  else
    posture=unregistered
  fi
  printf '%s\t%s\n' "$clone" "$posture"
}

case "$SUB" in
  show) cmd_show "$@" ;;
  label) cmd_label "$@" ;;
  comment) cmd_comment "$@" ;;
  comment-update) cmd_comment_update "$@" ;;
  checklist) cmd_checklist "$@" ;;
  project) cmd_project "$@" ;;
esac
