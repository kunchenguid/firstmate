# shellcheck shell=bash
# Shared primitives for firstmate's durable fleet data contracts.
# Usage: . bin/fm-outcome-lib.sh
#
# This library owns the WIRE SHAPE of three artifacts and nothing else: it never
# decides when one is produced, never resolves a work item, and never calls a
# forge.
#
#   data/<id>/outcome.json     schema fm-outcome-manifest.v1 - the durable
#                              completion manifest. Written atomically before
#                              teardown removes state/<id>.meta, so a task stays
#                              in history after its volatile records are gone.
#   data/<id>/work-items.json  schema fm-work-items.v1 - forge- and host-agnostic
#                              references to the work items a task traces back to.
#                              Population and per-forge enrichment belong to the
#                              project-issue-linkage owner; this library owns only
#                              storage, validation, and transport.
#   state/<id>.pr-status       schema fm-pr-status.v1 - the last normalized
#                              review/check/mergeability observation for a task's
#                              PR, cached so read-only consumers never call a forge.
#
# Secret safety is enforced, not documented: shared readers validate every
# stored value against its wire type, enumeration, shape, and length cap before
# a manifest or snapshot can project it, and manifest publication also checks a
# fixed recursive key allowlist.
#
# docs/fleet-data-contracts.md owns field ownership and consumer guarantees.

FM_OUTCOME_MANIFEST_SCHEMA=fm-outcome-manifest.v1
FM_WORK_ITEMS_SCHEMA=fm-work-items.v1
FM_PR_STATUS_SCHEMA=fm-pr-status.v1

# Caps on every free-text field that reaches a durable artifact.
FM_OUTCOME_TEXT_MAX=${FM_OUTCOME_TEXT_MAX:-240}
FM_OUTCOME_URL_MAX=${FM_OUTCOME_URL_MAX:-512}
FM_OUTCOME_RECEIPT_MAX=${FM_OUTCOME_RECEIPT_MAX:-200}
FM_OUTCOME_HOST_MAX=${FM_OUTCOME_HOST_MAX:-253}
FM_OUTCOME_PATH_MAX=${FM_OUTCOME_PATH_MAX:-480}
FM_OUTCOME_OWNER_MAX=${FM_OUTCOME_OWNER_MAX:-400}
FM_OUTCOME_REPO_MAX=${FM_OUTCOME_REPO_MAX:-200}
FM_OUTCOME_SOURCE_MAX=${FM_OUTCOME_SOURCE_MAX:-40}

_FM_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_OUTCOME_LIB_DIR="."
if ! declare -F fm_sup_stat_mtime >/dev/null 2>&1; then
  # shellcheck source=bin/fm-supervision-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_OUTCOME_LIB_DIR/fm-supervision-lib.sh"
fi
if ! declare -F fm_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_OUTCOME_LIB_DIR/fm-pr-lib.sh"
fi

# Last value of a key=value line, for the small key=value sidecars this library
# reads. Kept local so the data-contract layer never depends on the runtime
# backend library.
fm_outcome_kv_get() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_outcome_now_epoch() {
  if [ -n "${FM_OUTCOME_NOW_EPOCH:-}" ]; then
    printf '%s' "$FM_OUTCOME_NOW_EPOCH"
  else
    date -u +%s
  fi
}

# Portable epoch -> ISO-8601 UTC. BSD date takes -r <epoch>, GNU date -d @<epoch>.
fm_outcome_iso() {  # <epoch>
  local epoch=$1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || return 1
}

fm_outcome_now_iso() {
  fm_outcome_iso "$(fm_outcome_now_epoch)"
}

fm_outcome_iso_valid() {  # <iso>
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ISO-8601 UTC mtime of a path, or empty when unreadable.
fm_outcome_path_iso() {  # <path>
  local m
  [ -e "$1" ] || return 0
  m=$(fm_sup_stat_mtime "$1") || return 0
  [ -n "$m" ] || return 0
  fm_outcome_iso "$m" 2>/dev/null || true
}


# Single-line, control-character-free, length-capped free text.
# Every durable free-text field passes through here so a captured payload,
# multi-line prompt, or terminal escape can never reach a manifest.
fm_outcome_text() {  # <text> [max]
  local text=$1 max=${2:-$FM_OUTCOME_TEXT_MAX}
  printf '%s' "$text" \
    | tr -d '\000-\010\013\014\016-\037\177' \
    | tr '\t\n\r' '   ' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' \
    | cut -c "1-$max"
}

# Shared jq definitions for the canonical structured-backlog title parser.
# The fleet snapshot and the outcome manifest both use this exact program so
# trailing tasks-axi metadata is removed without stripping title parentheses.
FM_OUTCOME_BACKLOG_TITLE_JQ=
IFS= read -r -d '' FM_OUTCOME_BACKLOG_TITLE_JQ <<'JQ' || true
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
JQ

fm_outcome_backlog_title() {  # <backlog-path> <id>
  local backlog=$1 id=$2
  [ -f "$backlog" ] && [ ! -L "$backlog" ] || return 0
  jq -Rnr --arg id "$id" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
'"$FM_OUTCOME_BACKLOG_TITLE_JQ"'
    def row_match($line):
      ($line | capture("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
      ($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?);
    [inputs | row_match(.) | select(. != null) | select((.id | trim) == $id) | title_of(.rest)][0] // ""
  ' "$backlog"
}

# ---------------------------------------------------------------------------
# Atomic publication
# ---------------------------------------------------------------------------

# Write <json> to <dest> atomically and privately: a same-directory temp file,
# mode 0600, parsed back before the rename. A reader either sees the previous
# complete artifact or the new complete artifact, never a torn one.
fm_outcome_json_write() {  # <dest> <json>
  local dest=$1 json=$2 dir tmp
  dir=$(dirname "$dest")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ ! -L "$dest" ] || return 1
  [ ! -e "$dest" ] || [ -f "$dest" ] || return 1
  tmp=$(mktemp "$dir/.fm-outcome.XXXXXX") || return 1
  if ! printf '%s\n' "$json" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! jq -e . "$tmp" >/dev/null 2>&1 \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Read a JSON artifact, refusing anything that is not a plain regular file
# carrying a valid top-level object with the expected schema id. A symlinked
# artifact is refused rather than followed.
fm_outcome_json_read() {  # <path> <expected-schema>
  local path=$1 schema=$2
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  jq -e --arg schema "$schema" \
    'if type == "object" and .schema == $schema then . else error("schema") end' \
    "$path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Work-item references (storage and transport only)
# ---------------------------------------------------------------------------

FM_WI_URL=
FM_WI_FORGE=
FM_WI_HOST=
FM_WI_PATH=
FM_WI_OWNER=
FM_WI_REPO=
FM_WI_NUMBER=
FM_WI_KIND=

fm_outcome_forge_token_valid() {  # <forge>
  case "$1" in
    ''|*[!a-z0-9._-]*) return 1 ;;
    *) [ "${#1}" -le 32 ] ;;
  esac
}

# Parse an absolute work-item URL into forge/host/path/owner/repo/number/kind.
# Deliberately host-agnostic: an unrecognized host still round-trips with
# forge=unknown rather than being rejected or guessed at. An explicit forge
# override (the linkage owner's registry decision) always wins.
fm_outcome_work_item_parse() {  # <url> [forge-override]
  local url=$1 override=${2:-} rest scheme
  FM_WI_URL=; FM_WI_FORGE=; FM_WI_HOST=; FM_WI_PATH=
  FM_WI_OWNER=; FM_WI_REPO=; FM_WI_NUMBER=; FM_WI_KIND=

  [ -n "$url" ] || return 1
  [ "${#url}" -le "$FM_OUTCOME_URL_MAX" ] || return 1
  case "$url" in
    *[[:space:]]*|*'"'*|*\\*) return 1 ;;
    https://*) scheme=https; rest=${url#https://} ;;
    http://*) scheme=http; rest=${url#http://} ;;
    *) return 1 ;;
  esac
  rest=${rest%%#*}
  rest=${rest%%\?*}
  case "$rest" in
    */*) FM_WI_HOST=${rest%%/*}; rest=${rest#*/} ;;
    *) FM_WI_HOST=$rest; rest= ;;
  esac
  case "$FM_WI_HOST" in
    ''|*[!A-Za-z0-9.:_-]*) return 1 ;;
  esac
  [ "${#FM_WI_HOST}" -le "$FM_OUTCOME_HOST_MAX" ] || return 1
  rest=${rest%/}
  case "$rest" in
    *..*) return 1 ;;
    *[!A-Za-z0-9./_-]*) return 1 ;;
  esac

  if [[ $rest =~ ^(.+)/-/(issues|merge_requests)/([1-9][0-9]*)$ ]]; then
    FM_WI_PATH=${BASH_REMATCH[1]}
    FM_WI_KIND=${BASH_REMATCH[2]}
    FM_WI_NUMBER=${BASH_REMATCH[3]}
    [ -z "$override" ] && FM_WI_FORGE=gitlab
  elif [[ $rest =~ ^(.+)/(issues|pull|pulls|merge_requests)/([1-9][0-9]*)$ ]]; then
    FM_WI_PATH=${BASH_REMATCH[1]}
    FM_WI_KIND=${BASH_REMATCH[2]}
    FM_WI_NUMBER=${BASH_REMATCH[3]}
  elif [[ $rest =~ ^(.+)/-/(issues|merge_requests)/([0-9]+)$ ]] \
    || [[ $rest =~ ^(.+)/(issues|pull|pulls|merge_requests)/([0-9]+)$ ]]; then
    return 1
  else
    FM_WI_PATH=$rest
    FM_WI_KIND=unknown
    FM_WI_NUMBER=
  fi
  case "$FM_WI_KIND" in
    issues) FM_WI_KIND=issue ;;
    pull|pulls) FM_WI_KIND=pull_request ;;
    merge_requests) FM_WI_KIND=merge_request ;;
  esac

  if [ -n "$override" ]; then
    fm_outcome_forge_token_valid "$override" || return 1
    FM_WI_FORGE=$override
  elif [ -z "$FM_WI_FORGE" ]; then
    case "$FM_WI_HOST" in
      github.com) FM_WI_FORGE=github ;;
      gitlab.com|gitlab.*) FM_WI_FORGE=gitlab ;;
      *) FM_WI_FORGE=unknown ;;
    esac
  fi

  case "$FM_WI_PATH" in
    '') FM_WI_OWNER=; FM_WI_REPO= ;;
    */*) FM_WI_OWNER=${FM_WI_PATH%/*}; FM_WI_REPO=${FM_WI_PATH##*/} ;;
    *) FM_WI_OWNER=; FM_WI_REPO=$FM_WI_PATH ;;
  esac
  [ "${#FM_WI_PATH}" -le "$FM_OUTCOME_PATH_MAX" ] || return 1
  [ "${#FM_WI_OWNER}" -le "$FM_OUTCOME_OWNER_MAX" ] || return 1
  [ "${#FM_WI_REPO}" -le "$FM_OUTCOME_REPO_MAX" ] || return 1

  if [ -n "$rest" ]; then
    FM_WI_URL="$scheme://$FM_WI_HOST/$rest"
  else
    FM_WI_URL="$scheme://$FM_WI_HOST"
  fi
}

fm_outcome_work_item_origin_valid() {  # <origin>
  case "$1" in intake|pr-linked) return 0 ;; *) return 1 ;; esac
}

fm_outcome_work_item_state_valid() {  # <state>
  case "$1" in ''|open|closed|merged|unknown) return 0 ;; *) return 1 ;; esac
}

# One normalized reference object. Enrichment stays nullable on purpose:
# consumers must render a reference that has never been enriched.
fm_outcome_work_item_json() {  # <url> <origin> [forge-override] [title] [state] [observed-at] [enrichment-source]
  local url=$1 origin=$2 override=${3:-} title=${4:-} state=${5:-} observed=${6:-} src=${7:-}
  fm_outcome_work_item_origin_valid "$origin" || return 1
  fm_outcome_work_item_state_valid "$state" || return 1
  fm_outcome_work_item_parse "$url" "$override" || return 1
  title=$(fm_outcome_text "$title")
  src=$(fm_outcome_text "$src" "$FM_OUTCOME_SOURCE_MAX")
  jq -n \
    --arg url "$FM_WI_URL" \
    --arg forge "$FM_WI_FORGE" \
    --arg host "$FM_WI_HOST" \
    --arg path "$FM_WI_PATH" \
    --arg owner "$FM_WI_OWNER" \
    --arg repo "$FM_WI_REPO" \
    --arg number "$FM_WI_NUMBER" \
    --arg kind "$FM_WI_KIND" \
    --arg origin "$origin" \
    --arg title "$title" \
    --arg state "$state" \
    --arg observed "$observed" \
    --arg src "$src" \
    'def blank($v): if $v == "" then null else $v end;
     {url:$url,
      forge:$forge,
      host:$host,
      path:blank($path),
      owner:blank($owner),
      repo:blank($repo),
      number:(if $number == "" then null else ($number | tonumber) end),
      kind:$kind,
      origin:$origin,
      enrichment:{title:blank($title),
                  state:blank($state),
                  observed_at:blank($observed),
                  source:blank($src)}}'
}

fm_outcome_work_items_path() {  # <data-dir> <id>
  printf '%s/%s/work-items.json' "$1" "$2"
}

# The empty document is the same shape as a populated one, so a task with no
# references and a task whose store was never created look identical to a
# consumer.
fm_outcome_work_items_empty() {  # <id>
  jq -n --arg schema "$FM_WORK_ITEMS_SCHEMA" --arg id "$1" \
    '{schema:$schema,task_id:$id,references:[]}'
}

fm_outcome_work_item_ref_valid() {  # <reference-json>
  local ref=$1 url forge host path owner repo number kind
  jq -e \
    --argjson text_max "$FM_OUTCOME_TEXT_MAX" \
    --argjson source_max "$FM_OUTCOME_SOURCE_MAX" '
      def clean_string($max):
        type == "string" and length <= $max and (test("[\u0000-\u001f\u007f]") | not);
      type == "object"
      and (keys == ["enrichment","forge","host","kind","number","origin","owner","path","repo","url"])
      and (.url | type == "string")
      and (.forge | type == "string")
      and (.host | type == "string")
      and (.path == null or (.path | type == "string"))
      and (.owner == null or (.owner | type == "string"))
      and (.repo == null or (.repo | type == "string"))
      and (.number == null or ((.number | type) == "number" and .number > 0 and (.number | floor) == .number))
      and (.kind | IN("issue","pull_request","merge_request","unknown"))
      and (.origin | IN("intake","pr-linked"))
      and (.enrichment | type == "object")
      and (.enrichment | keys == ["observed_at","source","state","title"])
      and (.enrichment.title == null or (.enrichment.title | clean_string($text_max)))
      and (.enrichment.state == null or (.enrichment.state | IN("open","closed","merged","unknown")))
      and (.enrichment.observed_at == null or (.enrichment.observed_at | type == "string"))
      and (.enrichment.source == null or (.enrichment.source | clean_string($source_max)))
    ' >/dev/null 2>&1 <<<"$ref" || return 1

  url=$(jq -r '.url' <<<"$ref")
  forge=$(jq -r '.forge' <<<"$ref")
  host=$(jq -r '.host' <<<"$ref")
  path=$(jq -r '.path // ""' <<<"$ref")
  owner=$(jq -r '.owner // ""' <<<"$ref")
  repo=$(jq -r '.repo // ""' <<<"$ref")
  number=$(jq -r '.number // ""' <<<"$ref")
  kind=$(jq -r '.kind' <<<"$ref")
  fm_outcome_work_item_parse "$url" "$forge" || return 1
  [ "$FM_WI_URL" = "$url" ] && [ "$FM_WI_FORGE" = "$forge" ] \
    && [ "$FM_WI_HOST" = "$host" ] && [ "$FM_WI_PATH" = "$path" ] \
    && [ "$FM_WI_OWNER" = "$owner" ] && [ "$FM_WI_REPO" = "$repo" ] \
    && [ "$FM_WI_NUMBER" = "$number" ] && [ "$FM_WI_KIND" = "$kind" ] || return 1

  local observed
  observed=$(jq -r '.enrichment.observed_at // ""' <<<"$ref")
  [ -z "$observed" ] || fm_outcome_iso_valid "$observed"
}

fm_outcome_work_items_doc_valid() {  # <document-json> <id>
  local doc=$1 id=$2
  jq -e --arg schema "$FM_WORK_ITEMS_SCHEMA" --arg id "$id" '
    type == "object"
    and (keys == ["references","schema","task_id"])
    and .schema == $schema
    and .task_id == $id
    and (.references | type == "array")
  ' >/dev/null 2>&1 <<<"$doc" || return 1
  fm_outcome_work_item_references_valid "$(jq -c '.references' <<<"$doc")"
}

fm_outcome_work_item_references_valid() {  # <references-json>
  local refs=$1 ref
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$refs" || return 1
  while IFS= read -r ref; do
    fm_outcome_work_item_ref_valid "$ref" || return 1
  done < <(jq -c '.[]' <<<"$refs")
}

fm_outcome_work_items_doc_read() {  # <data-dir> <id>
  local path doc
  path=$(fm_outcome_work_items_path "$1" "$2")
  doc=$(fm_outcome_json_read "$path" "$FM_WORK_ITEMS_SCHEMA" 2>/dev/null) || return 1
  fm_outcome_work_items_doc_valid "$doc" "$2" || return 1
  printf '%s\n' "$doc"
}

fm_outcome_work_items_read() {  # <data-dir> <id>
  fm_outcome_work_items_doc_read "$1" "$2" 2>/dev/null \
    || fm_outcome_work_items_empty "$2"
}

fm_outcome_work_items_write() {  # <data-dir> <id> <references-json>
  local data=$1 id=$2 refs=$3 dir doc
  doc=$(jq -n --arg schema "$FM_WORK_ITEMS_SCHEMA" --arg id "$id" \
    --slurpfile refs_doc <(printf '%s' "$refs") \
    '{schema:$schema,task_id:$id,references:($refs_doc[0] // [])}') || return 1
  fm_outcome_work_items_doc_valid "$doc" "$id" || return 1
  dir="$data/$id"
  mkdir -p "$dir" || return 1
  fm_outcome_json_write "$(fm_outcome_work_items_path "$data" "$id")" "$doc"
}

# ---------------------------------------------------------------------------
# Normalized PR review / check / mergeability state
# ---------------------------------------------------------------------------

fm_outcome_pr_status_path() {  # <state-dir> <id>
  printf '%s/%s.pr-status' "$1" "$2"
}

fm_outcome_pr_status_unknown() {
  jq -n '{state:"unknown",draft:null,review:"unknown",checks:"unknown",
          mergeable:"unknown",head:null,observed_at:null,source:"absent"}'
}

# The cached observation for a task, or the unknown object when none exists.
# Read-only consumers use this instead of calling a forge.
fm_outcome_pr_status_read() {  # <state-dir> <id> <expected-url>
  local doc expected=${3:-}
  if [ -n "$expected" ] \
    && doc=$(fm_outcome_pr_status_doc_read "$1" "$2") \
    && [ "$(jq -r '.url' <<<"$doc")" = "$expected" ]; then
    jq -c '.status' <<<"$doc"
    return 0
  fi
  fm_outcome_pr_status_unknown
}

fm_outcome_pr_status_doc_read() {  # <state-dir> <id>
  local doc
  doc=$(fm_outcome_json_read "$(fm_outcome_pr_status_path "$1" "$2")" "$FM_PR_STATUS_SCHEMA" 2>/dev/null) \
    || return 1
  fm_outcome_pr_status_doc_valid "$doc" || return 1
  printf '%s\n' "$doc"
}

# Map one forge's vocabulary onto the normalized enumerations. Only these
# enumerated tokens are ever stored; a raw API payload never reaches disk.
fm_outcome_pr_state_normalize() {  # <state> <merged-bool> <draft-bool>
  local state merged=$2 draft=$3
  state=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if [ "$merged" = true ] || [ "$state" = merged ]; then printf 'merged'; return 0; fi
  case "$state" in
    open|opened|reopened) if [ "$draft" = true ]; then printf 'draft'; else printf 'open'; fi ;;
    closed|locked) printf 'closed' ;;
    *) printf 'unknown' ;;
  esac
}

fm_outcome_pr_review_normalize() {  # <review-decision>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    approved) printf 'approved' ;;
    changes_requested) printf 'changes_requested' ;;
    review_required) printf 'review_required' ;;
    '') printf 'none' ;;
    *) printf 'unknown' ;;
  esac
}

fm_outcome_pr_checks_normalize() {  # <rollup>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    success|passed|passing) printf 'passing' ;;
    failure|failed|error|failing|canceled|cancelled|timed_out) printf 'failing' ;;
    pending|running|queued|in_progress|waiting|expected|created|preparing|scheduled|manual) printf 'pending' ;;
    neutral|skipped|none) printf 'none' ;;
    '') printf 'none' ;;
    *) printf 'unknown' ;;
  esac
}

fm_outcome_pr_mergeable_normalize() {  # <mergeable> <merge-state-status>
  local mergeable state
  mergeable=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  state=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  # GitHub mergeStateStatus and GitLab detailed_merge_status share this slot.
  case "$state" in
    dirty|conflicting|conflict|broken_status) printf 'conflicting'; return 0 ;;
    blocked|behind|draft|not_approved|need_rebase|requested_changes|ci_still_running|ci_must_pass|discussions_not_resolved) printf 'blocked'; return 0 ;;
    clean|has_hooks|unstable|mergeable) printf 'mergeable'; return 0 ;;
  esac
  case "$mergeable" in
    mergeable|true|yes|can_be_merged) printf 'mergeable' ;;
    conflicting|false|no|cannot_be_merged) printf 'conflicting' ;;
    *) printf 'unknown' ;;
  esac
}

fm_outcome_sha_valid() {  # <sha>
  fm_pr_head_valid "$1"
}

fm_outcome_pr_status_doc_valid() {  # <document-json>
  local doc=$1 url provider host path number head observed
  jq -e --arg schema "$FM_PR_STATUS_SCHEMA" --argjson source_max "$FM_OUTCOME_SOURCE_MAX" '
    type == "object"
    and (keys == ["host","number","path","provider","schema","status","url"])
    and .schema == $schema
    and (.url | type == "string")
    and (.provider | IN("github","gitlab"))
    and (.host | type == "string")
    and (.path | type == "string")
    and ((.number | type) == "number" and .number > 0 and (.number | floor) == .number)
    and (.status | type == "object")
    and (.status | keys == ["checks","draft","head","mergeable","observed_at","review","source","state"])
    and (.status.state | IN("open","draft","closed","merged","unknown"))
    and (.status.draft == null or (.status.draft | type == "boolean"))
    and (.status.review | IN("approved","changes_requested","review_required","none","unknown"))
    and (.status.checks | IN("passing","failing","pending","none","unknown"))
    and (.status.mergeable | IN("mergeable","conflicting","blocked","unknown"))
    and (.status.head == null or (.status.head | type == "string"))
    and (.status.observed_at | type == "string")
    and (.provider as $provider
         | .status.source
         | type == "string" and length <= $source_max and . == $provider)
  ' >/dev/null 2>&1 <<<"$doc" || return 1

  url=$(jq -r '.url' <<<"$doc")
  provider=$(jq -r '.provider' <<<"$doc")
  host=$(jq -r '.host' <<<"$doc")
  path=$(jq -r '.path' <<<"$doc")
  number=$(jq -r '.number' <<<"$doc")
  head=$(jq -r '.status.head // ""' <<<"$doc")
  observed=$(jq -r '.status.observed_at' <<<"$doc")
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_URL" = "$url" ] && [ "$FM_PR_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_HOST" = "$host" ] && [ "$FM_PR_PATH" = "$path" ] \
    && [ "$FM_PR_NUMBER" = "$number" ] || return 1
  [ -z "$head" ] || fm_outcome_sha_valid "$head" || return 1
  fm_outcome_iso_valid "$observed"
}

# Build the whole cached document from already-normalized parts.
fm_outcome_pr_status_doc() {  # <url> <provider> <host> <path> <number> <state> <draft> <review> <checks> <mergeable> <head> <observed-at> <source>
  local head=${11} doc
  fm_outcome_sha_valid "$head" || head=
  doc=$(jq -n \
    --arg schema "$FM_PR_STATUS_SCHEMA" \
    --arg url "$1" --arg provider "$2" --arg host "$3" --arg path "$4" --arg number "$5" \
    --arg state "$6" --arg draft "$7" --arg review "$8" --arg checks "$9" \
    --arg mergeable "${10}" --arg head "$head" --arg observed "${12}" --arg source "${13}" \
    'def blank($v): if $v == "" then null else $v end;
     {schema:$schema,
      url:$url,
      provider:$provider,
      host:$host,
      path:$path,
      number:(if $number == "" then null else ($number | tonumber) end),
      status:{state:$state,
              draft:(if $draft == "true" then true elif $draft == "false" then false else null end),
              review:$review,
              checks:$checks,
              mergeable:$mergeable,
              head:blank($head),
              observed_at:blank($observed),
              source:$source}}') || return 1
  fm_outcome_pr_status_doc_valid "$doc" || return 1
  printf '%s\n' "$doc"
}

fm_outcome_pr_status_write() {  # <state-dir> <id> <document-json>
  fm_outcome_pr_status_doc_valid "$3" || return 1
  fm_outcome_json_write "$(fm_outcome_pr_status_path "$1" "$2")" "$3"
}

# ---------------------------------------------------------------------------
# GBrain capture receipt (optional provider)
# ---------------------------------------------------------------------------

fm_outcome_gbrain_path() {  # <state-dir> <id>
  printf '%s/%s.gbrain' "$1" "$2"
}

# An absent provider is a first-class answer, not an error: status=absent with
# every other field null. A present record contributes only an enumerated
# status, an opaque receipt token, a timestamp, and capped detail text.
fm_outcome_gbrain_json() {  # <state-dir> <id>
  local path status='' receipt='' observed='' detail=''
  path=$(fm_outcome_gbrain_path "$1" "$2")
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    status=$(fm_outcome_kv_get "$path" status)
    receipt=$(fm_outcome_kv_get "$path" receipt)
    observed=$(fm_outcome_kv_get "$path" observed_at)
    detail=$(fm_outcome_text "$(fm_outcome_kv_get "$path" detail)")
    case "$status" in
      captured|pending|failed|skipped) ;;
      *) status=unknown ;;
    esac
    case "$receipt" in
      *[!A-Za-z0-9._:/-]*) receipt= ;;
      *) [ "${#receipt}" -le "$FM_OUTCOME_RECEIPT_MAX" ] || receipt= ;;
    esac
    fm_outcome_iso_valid "$observed" || observed=
  else
    status=absent
  fi
  jq -n --arg status "$status" --arg receipt "$receipt" \
    --arg observed "$observed" --arg detail "$detail" \
    'def blank($v): if $v == "" then null else $v end;
     {status:$status,receipt:blank($receipt),observed_at:blank($observed),detail:blank($detail)}'
}

# ---------------------------------------------------------------------------
# Outcome manifest
# ---------------------------------------------------------------------------

fm_outcome_manifest_path() {  # <data-dir> <id>
  printf '%s/%s/outcome.json' "$1" "$2"
}

# The complete recursive key allowlist for fm-outcome-manifest.v1. Array
# elements collapse to [], so every object under work_items.references shares
# one entry. Adding a field here is the deliberate act that lets it be
# published; anything not listed is refused at write time.
fm_outcome_manifest_allowed_keys() {
  cat <<'EOF'
schema
task_id
home
title
project
kind
mode
yolo
harness
model
effort
timestamps
timestamps.created
timestamps.started
timestamps.completed
timestamp_sources
timestamp_sources.created
timestamp_sources.started
timestamp_sources.completed
outcome
outcome.state
outcome.detail
outcome.source
outcome.forced
pr
pr.url
pr.provider
pr.host
pr.path
pr.number
pr.head
pr.status
pr.status.state
pr.status.draft
pr.status.review
pr.status.checks
pr.status.mergeable
pr.status.head
pr.status.observed_at
pr.status.source
report
report.path
report.present
attribution
attribution.backend
attribution.endpoint
attribution.endpoint.target
attribution.endpoint.task_id
attribution.worktree
attribution.task_tmp
attribution.traceparent
attribution.secondmate_home
work_items
work_items.schema
work_items.references
work_items.references[]
work_items.references[].url
work_items.references[].forge
work_items.references[].host
work_items.references[].path
work_items.references[].owner
work_items.references[].repo
work_items.references[].number
work_items.references[].kind
work_items.references[].origin
work_items.references[].enrichment
work_items.references[].enrichment.title
work_items.references[].enrichment.state
work_items.references[].enrichment.observed_at
work_items.references[].enrichment.source
gbrain
gbrain.status
gbrain.receipt
gbrain.observed_at
gbrain.detail
recorded_at
EOF
}

# Exit 0 when every path in <manifest-json> is allowlisted. On failure the
# unexpected paths are printed, so a refusal names what it refused.
fm_outcome_manifest_keys_valid() {  # <manifest-json>
  local extra
  extra=$(jq -rn \
    --slurpfile doc <(printf '%s' "$1") \
    --rawfile allowed <(fm_outcome_manifest_allowed_keys) '
      ($allowed | split("\n") | map(select(length > 0))) as $ok
      | ($doc[0] // error("fm-outcome: empty manifest"))
      | [ paths
          | map(if type == "number" then "[]" else . end)
          | reduce .[] as $seg (""; if . == "" then $seg
                                    elif $seg == "[]" then . + "[]"
                                    else . + "." + $seg end) ]
      | unique
      | map(select(. as $p | ($ok | index($p)) == null))
      | .[]') || return 1
  [ -z "$extra" ] && return 0
  printf '%s\n' "$extra" >&2
  return 1
}

fm_outcome_manifest_values_valid() {  # <manifest-json>
  local json=$1 refs status source pr_doc
  jq -e --arg work_schema "$FM_WORK_ITEMS_SCHEMA" '
    (.work_items | type == "object" and keys == ["references","schema"])
    and .work_items.schema == $work_schema
    and (.work_items.references | type == "array")
    and (.pr | type == "object")
    and (.pr.status | type == "object")
  ' >/dev/null 2>&1 <<<"$json" || return 1
  refs=$(jq -c '.work_items.references' <<<"$json")
  fm_outcome_work_item_references_valid "$refs" || return 1

  status=$(jq -c '.pr.status' <<<"$json")
  source=$(jq -r '.source // ""' <<<"$status")
  if [ "$source" = absent ]; then
    jq -e '
      keys == ["checks","draft","head","mergeable","observed_at","review","source","state"]
      and .state == "unknown" and .draft == null and .review == "unknown"
      and .checks == "unknown" and .mergeable == "unknown" and .head == null
      and .observed_at == null and .source == "absent"
    ' >/dev/null 2>&1 <<<"$status"
    return
  fi
  pr_doc=$(jq -c --arg schema "$FM_PR_STATUS_SCHEMA" '
    {schema:$schema,url:.pr.url,provider:.pr.provider,host:.pr.host,
     path:.pr.path,number:.pr.number,status:.pr.status}
  ' <<<"$json") || return 1
  fm_outcome_pr_status_doc_valid "$pr_doc"
}

fm_outcome_manifest_write() {  # <data-dir> <id> <manifest-json>
  local data=$1 id=$2 json=$3
  mkdir -p "$data/$id" || return 1
  jq -e --arg schema "$FM_OUTCOME_MANIFEST_SCHEMA" --arg id "$id" \
    'if .schema == $schema and .task_id == $id then . else error("identity") end' \
    >/dev/null 2>&1 <<<"$json" || return 1
  fm_outcome_manifest_keys_valid "$json" || return 1
  fm_outcome_manifest_values_valid "$json" || return 1
  fm_outcome_json_write "$(fm_outcome_manifest_path "$data" "$id")" "$json"
}

fm_outcome_manifest_read() {  # <data-dir> <id>
  local doc
  doc=$(fm_outcome_json_read "$(fm_outcome_manifest_path "$1" "$2")" "$FM_OUTCOME_MANIFEST_SCHEMA") \
    || return 1
  fm_outcome_manifest_keys_valid "$doc" >/dev/null 2>&1 || return 1
  fm_outcome_manifest_values_valid "$doc" || return 1
  printf '%s\n' "$doc"
}

# Durable history as schema fm-outcome-history.v1, newest completion first.
# A manifest that no longer parses, is not a plain file, or exceeds the read
# bound is disclosed by id and reason rather than silently dropped, so a
# consumer can tell "nothing completed" from "one record is unreadable".
# bin/fm-outcome-manifest.sh list and bin/fm-fleet-snapshot.sh both call this,
# so the two views cannot drift.
#
# Deliberately free of temp files and of every external command the read-only
# fleet snapshot does not already depend on: the snapshot runs under hermetic
# restricted paths, so a history read must never be the thing that needs one
# more tool on PATH.
fm_outcome_history_json() {  # <data-dir> <limit>
  local data=$1 limit=$2 dir id path records='' malformed='' doc size
  local max_bytes=${FM_OUTCOME_HISTORY_MAX_BYTES:-65536}
  case "$limit" in ''|*[!0-9]*) return 2 ;; esac
  if [ -d "$data" ]; then
    for dir in "$data"/*/; do
      [ -d "$dir" ] || continue
      id=$(basename "$dir")
      path="${dir%/}/outcome.json"
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ -L "$path" ] || [ ! -f "$path" ]; then
        malformed=$malformed$(fm_outcome_history_reject "$id" "$path" not_a_regular_file)$'\n'
        continue
      fi
      size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$size" in ''|*[!0-9]*) size=0 ;; esac
      if [ "$size" -gt "$max_bytes" ]; then
        malformed=$malformed$(fm_outcome_history_reject "$id" "$path" too_large)$'\n'
        continue
      fi
      if ! doc=$(fm_outcome_json_read "$path" "$FM_OUTCOME_MANIFEST_SCHEMA" 2>/dev/null); then
        malformed=$malformed$(fm_outcome_history_reject "$id" "$path" unreadable_or_wrong_schema)$'\n'
        continue
      fi
      if ! fm_outcome_manifest_keys_valid "$doc" 2>/dev/null; then
        malformed=$malformed$(fm_outcome_history_reject "$id" "$path" unexpected_fields)$'\n'
        continue
      fi
      if ! fm_outcome_manifest_values_valid "$doc" 2>/dev/null; then
        malformed=$malformed$(fm_outcome_history_reject "$id" "$path" invalid_values)$'\n'
        continue
      fi
      records=$records$(printf '%s' "$doc" | jq -c .)$'\n'
    done
  fi
  jq -n --argjson limit "$limit" \
    --slurpfile records_doc <(printf '%s' "$records" | jq -s '.') \
    --slurpfile malformed_doc <(printf '%s' "$malformed" | jq -s '.') \
    'def doc($v): ($v[0] // []);
     (doc($records_doc) | sort_by([(.timestamps.completed // ""), .task_id]) | reverse) as $all
     | {schema:"fm-outcome-history.v1",
        records:($all[0:$limit]),
        total:($all | length),
        shown:($all[0:$limit] | length),
        truncated:(($all | length) > $limit),
        malformed:doc($malformed_doc)}'
}

fm_outcome_history_reject() {  # <id> <path> <reason>
  jq -cn --arg id "$1" --arg path "$2" --arg reason "$3" \
    '{id:$id,path:$path,reason:$reason}'
}
