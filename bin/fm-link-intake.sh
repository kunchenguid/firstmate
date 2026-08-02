#!/usr/bin/env bash
# fm-link-intake.sh - idempotently store validated, private Firstmate link-intake records.
#
# Usage:
#   bin/fm-link-intake.sh upsert --url URL --source-type TYPE --title TITLE --summary SUMMARY --terms TERMS --claim TEXT [--claim TEXT ...] [--canonical-url URL] [--retrieved-at YYYY-MM-DD] [--transcript-file PATH | --transcript-unavailable REASON] [--failure REASON] [--no-scout] [--scout-repo NAME]
#   bin/fm-link-intake.sh prepare-scout --url URL [--scout-repo NAME]
#   bin/fm-link-intake.sh validate <URL>
#   bin/fm-link-intake.sh validate --all
#   bin/fm-link-intake.sh --help
#
# Records and the searchable index live in the generation selected by
# $FM_HOME/data/link-intake/current.
# The helper owns their exact Markdown and TSV formats, canonicalization, validation,
# history snapshots, and single-switch process-crash atomic publication.
# It does not issue filesystem sync barriers, so power-loss durability depends on
# the host filesystem.
# It never retrieves pages, downloads media, authenticates, or makes external changes.
# A caller supplies only normalized public or otherwise authorized metadata after using
# the appropriate existing browser or media tool.
# Video and audio require either a transcript file to retain privately or an explicit
# unavailable reason, unless the retrieval itself failed, in which case that failure is
# recorded as the transcript reason too.
#
# Storing a retrievable record also prepares one queued ingest scout for that link:
# a scout brief scaffolded through bin/fm-brief.sh and a queued backlog item filed
# through the configured backlog backend. It never spawns, dispatches, or starts the
# scout, so firstmate keeps dispatch authority, spawn safety, dispatch-profile
# consultation, and capacity judgment. `--no-scout` skips preparation for this
# invocation, and `prepare-scout` prepares or repairs one for an already-stored record.
# The scout task id is derived from the canonical URL alone, so repeated intake of the
# same link converges on the same brief and backlog item instead of duplicating work.
# An inaccessible record prepares no scout because there is nothing to ingest.
# Scout preparation happens after the record is published: when it fails, the record is
# still stored and the command exits 3 so the failure is visible and repairable. Explicit
# manual mode prints the item to add; an unavailable tasks-axi backend fails preparation.
# Bash 3.2 compatible.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
LINK_ROOT="$FM_HOME/data/link-intake"
GENERATIONS_DIR="$LINK_ROOT/generations"
CURRENT_LINK="$LINK_ROOT/current"
LOCK_DIR="$LINK_ROOT/.update-lock"
SCOUT_REPO_DEFAULT=firstmate
LOCK_HELD=0
LOCK_OWNER_DIR=
STAGED_GENERATION=
STAGED_LINK=
CURRENT_GENERATION=
QUIET_CURRENT_GENERATION=

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

remove_generation() {
  local generation=$1
  case "$generation" in
    "$GENERATIONS_DIR"/.generation.*)
      rm -rf -- "$generation"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_current_quiet() {
  local target name
  QUIET_CURRENT_GENERATION=
  [ -L "$CURRENT_LINK" ] || return 1
  target=$(readlink "$CURRENT_LINK") || return 1
  case "$target" in
    generations/.generation.*) ;;
    *) return 1 ;;
  esac
  name=${target#generations/}
  case "$name" in
    */*) return 1 ;;
  esac
  [ -d "$LINK_ROOT/$target" ] || return 1
  QUIET_CURRENT_GENERATION="$LINK_ROOT/$target"
}

cleanup() {
  local status=$? lock_target owner_name
  trap - EXIT HUP INT TERM
  if [ -n "$STAGED_LINK" ] && ! rm -f "$STAGED_LINK"; then
    printf 'error: temporary state link retained: %s\n' "$STAGED_LINK" >&2
    [ "$status" -ne 0 ] || status=2
  fi
  if [ -n "$STAGED_GENERATION" ]; then
    if resolve_current_quiet; then
      if [ "$QUIET_CURRENT_GENERATION" = "$STAGED_GENERATION" ]; then
        STAGED_GENERATION=
      elif remove_generation "$STAGED_GENERATION"; then
        STAGED_GENERATION=
      else
        printf 'error: recoverable staged generation retained: %s\n' "$STAGED_GENERATION" >&2
        [ "$status" -ne 0 ] || status=2
      fi
    else
      printf 'error: recoverable staged generation retained: %s\n' "$STAGED_GENERATION" >&2
      [ "$status" -ne 0 ] || status=2
    fi
  fi
  if [ -n "$LOCK_OWNER_DIR" ]; then
    owner_name=${LOCK_OWNER_DIR##*/}
    lock_target=$(readlink "$LOCK_DIR" 2>/dev/null || true)
    if [ "$LOCK_HELD" = 1 ]; then
      if [ "$lock_target" = "$owner_name" ]; then
        if rm -f "$LOCK_DIR"; then
          LOCK_HELD=0
        else
          printf 'error: link-intake lock retained: %s\n' "$LOCK_DIR" >&2
          [ "$status" -ne 0 ] || status=2
        fi
      else
        printf 'error: link-intake lock ownership retained: %s\n' "$LOCK_OWNER_DIR" >&2
        [ "$status" -ne 0 ] || status=2
      fi
    fi
    if [ "$LOCK_HELD" = 0 ]; then
      rm -f "$LOCK_OWNER_DIR/owner" 2>/dev/null || true
      rmdir "$LOCK_OWNER_DIR" 2>/dev/null || true
    fi
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage:
  bin/fm-link-intake.sh upsert --url URL --source-type TYPE --title TITLE --summary SUMMARY --terms TERMS --claim TEXT [--claim TEXT ...] [--canonical-url URL] [--retrieved-at YYYY-MM-DD] [--transcript-file PATH | --transcript-unavailable REASON] [--failure REASON] [--no-scout] [--scout-repo NAME]
  bin/fm-link-intake.sh prepare-scout --url URL [--scout-repo NAME]
  bin/fm-link-intake.sh validate <URL>
  bin/fm-link-intake.sh validate --all

Source types: article, web, video, audio, document, image, other.

`upsert` preserves every supplied original URL, snapshots a replaced record under
data/link-intake/current/history/, and prints the current record path as its first
line; any scout-preparation line follows it.
`--failure` creates a visible inaccessible record when title, summary, claims, and
terms cannot be obtained.
For video or audio, provide a legally accessible `--transcript-file` or explain why
it is unavailable with `--transcript-unavailable`.

A retrievable record also prepares one queued ingest scout: a brief at
data/<task-id>/brief.md and a queued backlog item. Preparation never spawns or
dispatches anything - firstmate decides what runs and when. `--no-scout` skips it
for this invocation, `--scout-repo` names the repo the scout works in (default
firstmate), and `prepare-scout` prepares or repairs one for a stored record.
Preparation is idempotent per canonical URL and exits 3 when the record was stored
but its scout could not be prepared. Explicit manual backlog mode prints the item
to add by hand; a missing or incompatible tasks-axi backend fails preparation.
EOF
}

require_one_line() {
  local field=$1 value=$2
  [ -n "$value" ] || die "$field is required"
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "$field must be one line without tabs" ;;
  esac
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    die 'shasum or sha256sum is required'
  fi
}

canonicalize_url() {
  local input=$1 without_fragment scheme rest authority suffix lowered_authority
  require_one_line URL "$input"
  without_fragment=${input%%#*}
  scheme=${without_fragment%%://*}
  case "$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')" in
    http|https) ;;
    *) die 'URL must use http or https' ;;
  esac
  rest=${without_fragment#*://}
  authority=${rest%%[/?]*}
  suffix=${rest#"$authority"}
  [ -n "$authority" ] || die 'URL must include a host'
  case "$authority" in
    *@*|*' '*|*\\*) die 'URL authority is not accepted' ;;
  esac
  scheme=$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')
  lowered_authority=$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')
  case "$scheme:$lowered_authority" in
    http:*:80) lowered_authority=${lowered_authority%:80} ;;
    https:*:443) lowered_authority=${lowered_authority%:443} ;;
  esac
  printf '%s://%s%s\n' "$scheme" "$lowered_authority" "$suffix"
}

url_host() {
  local rest authority
  rest=${1#*://}
  authority=${rest%%/*}
  authority=${authority%%\?*}
  printf '%s\n' "${authority%%:*}"
}

record_id_for() {
  printf '%s' "$1" | sha256
}

logical_record_path_for() {
  local id
  id=$(record_id_for "$1")
  printf '%s/records/%s.md\n' "$CURRENT_LINK" "$id"
}

is_calendar_date() {
  local value=$1 year month day maximum
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  year=${value%%-*}
  month=${value#*-}
  month=${month%%-*}
  day=${value##*-}
  year=$((10#$year))
  month=$((10#$month))
  day=$((10#$day))
  [ "$year" -ge 1 ] && [ "$month" -ge 1 ] && [ "$month" -le 12 ] && [ "$day" -ge 1 ] || return 1
  case "$month" in
    1|3|5|7|8|10|12) maximum=31 ;;
    4|6|9|11) maximum=30 ;;
    2)
      maximum=28
      if [ $((year % 400)) -eq 0 ] || { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; }; then
        maximum=29
      fi
      ;;
  esac
  [ "$day" -le "$maximum" ]
}

process_start_identity() {
  local identity
  identity=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | awk 'NF { $1=$1; print; exit }')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

LOCK_OWNER_PID=
LOCK_OWNER_START=

lock_owner_is_live() {
  local owner_file=$1 current_start
  LOCK_OWNER_PID=$(sed -n '1p' "$owner_file" 2>/dev/null || true)
  LOCK_OWNER_START=$(sed -n '2p' "$owner_file" 2>/dev/null || true)
  case "$LOCK_OWNER_PID" in
    ''|*[!0-9]*) return 2 ;;
  esac
  kill -0 "$LOCK_OWNER_PID" 2>/dev/null || return 1
  [ -n "$LOCK_OWNER_START" ] || return 2
  current_start=$(process_start_identity "$LOCK_OWNER_PID") || return 2
  [ "$current_start" = "$LOCK_OWNER_START" ]
}

create_symlink_no_target() {
  local source=$1 target=$2
  if ln --help 2>&1 | grep -F -q -- '--no-target-directory'; then
    ln -sT "$source" "$target"
  else
    ln -sh "$source" "$target"
  fi
}

acquire_lock() {
  local owner_path target stale stale_lock quarantined_target attempt=0 claim_name path owner_status self_start
  mkdir -p "$GENERATIONS_DIR" || die 'could not initialize link-intake storage'
  LOCK_OWNER_DIR=$(mktemp -d "$LINK_ROOT/.lock-owner.XXXXXX") \
    || die 'could not create link-intake lock claim'
  self_start=$(process_start_identity "$$") \
    || die 'could not identify link-intake lock process'
  printf '%s\n%s\n' "$$" "$self_start" > "$LOCK_OWNER_DIR/owner" \
    || die 'could not initialize link-intake lock claim'
  claim_name=${LOCK_OWNER_DIR##*/}
  while [ "$attempt" -lt 5 ]; do
    if create_symlink_no_target "$claim_name" "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      for path in "$LINK_ROOT"/.lock-owner.*; do
        [ -d "$path" ] || continue
        [ "$path" = "$LOCK_OWNER_DIR" ] && continue
        lock_owner_is_live "$path/owner"
        owner_status=$?
        [ "$owner_status" = 1 ] || continue
        rm -f "$path/owner" 2>/dev/null || true
        rmdir "$path" 2>/dev/null || true
      done
      for path in "$LINK_ROOT"/.stale-update-lock.*; do
        [ -L "$path" ] || continue
        rm -f "$path" 2>/dev/null || true
      done
      for path in "$LINK_ROOT"/.stale-lock-owner.*; do
        [ -d "$path" ] || continue
        rm -f "$path/owner" 2>/dev/null || true
        rmdir "$path" 2>/dev/null || true
      done
      return 0
    fi
    [ -L "$LOCK_DIR" ] || die 'link-intake update lock is invalid'
    target=$(readlink "$LOCK_DIR") || die 'link-intake update lock is unreadable'
    case "$target" in
      .lock-owner.*) ;;
      *) die 'link-intake update lock target is invalid' ;;
    esac
    case "$target" in
      */*) die 'link-intake update lock target is invalid' ;;
    esac
    owner_path="$LINK_ROOT/$target"
    stale="$LINK_ROOT/.stale-lock-owner.${target#.lock-owner.}"
    if [ ! -e "$owner_path" ] && [ ! -L "$owner_path" ]; then
      if [ -d "$stale" ] && mv "$stale" "$owner_path" 2>/dev/null; then
        attempt=$((attempt + 1))
        continue
      fi
      die "link-intake update lock owner is absent: $owner_path"
    fi
    if lock_owner_is_live "$owner_path/owner"; then
      die 'another link-intake update is in progress'
    else
      owner_status=$?
    fi
    [ "$owner_status" = 1 ] || die 'link-intake update lock owner identity is unreadable'
    if mv "$owner_path" "$stale" 2>/dev/null; then
      stale_lock="$LINK_ROOT/.stale-update-lock.${target#.lock-owner.}"
      [ ! -e "$stale_lock" ] && [ ! -L "$stale_lock" ] \
        || die "stale link-intake lock quarantine retained: $stale"
      mv "$LOCK_DIR" "$stale_lock" 2>/dev/null \
        || die "stale link-intake lock recovery retained: $stale"
      quarantined_target=$(readlink "$stale_lock" 2>/dev/null || true)
      [ "$quarantined_target" = "$target" ] \
        || die "stale link-intake lock quarantine retained: $stale_lock"
      rm -f "$stale_lock" || die "stale link-intake lock quarantine retained: $stale_lock"
      if [ -L "$stale" ]; then
        rm -f "$stale" || die "stale link-intake lock retained: $stale"
      else
        rm -f "$stale/owner" || die "stale link-intake lock retained: $stale"
        rmdir "$stale" || die "stale link-intake lock retained: $stale"
      fi
    fi
    attempt=$((attempt + 1))
  done
  die 'could not acquire link-intake update lock'
}

resolve_current() {
  local target name
  CURRENT_GENERATION=
  if [ ! -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
    return 1
  fi
  [ -L "$CURRENT_LINK" ] || die "link-intake current state is not a symbolic link: $CURRENT_LINK"
  target=$(readlink "$CURRENT_LINK") || die "link-intake current state is unreadable: $CURRENT_LINK"
  case "$target" in
    generations/.generation.*) ;;
    *) die "link-intake current state target is invalid: $target" ;;
  esac
  name=${target#generations/}
  case "$name" in
    */*) die "link-intake current state target is invalid: $target" ;;
  esac
  CURRENT_GENERATION="$LINK_ROOT/$target"
  [ -d "$CURRENT_GENERATION" ] || die "link-intake current generation is absent: $CURRENT_GENERATION"
}

prune_abandoned_generations() {
  local current=${1:-} generation
  for generation in "$GENERATIONS_DIR"/.generation.*; do
    [ -d "$generation" ] || continue
    [ -n "$current" ] && [ "$generation" = "$current" ] && continue
    remove_generation "$generation" || die "recoverable staged generation retained: $generation"
  done
}

create_staged_generation() {
  local current=${1:-}
  STAGED_GENERATION=$(mktemp -d "$GENERATIONS_DIR/.generation.XXXXXX") \
    || die 'could not create staged link-intake generation'
  if [ -n "$current" ]; then
    cp -R "$current/." "$STAGED_GENERATION/" || die 'could not copy current link-intake generation'
  else
    mkdir -p "$STAGED_GENERATION/records" "$STAGED_GENERATION/transcripts" "$STAGED_GENERATION/history" \
      || die 'could not initialize staged link-intake generation'
    printf 'canonical_url\trecord_id\tretrieved_at\tsource_type\ttitle\tstatus\tsearch_terms\n' \
      > "$STAGED_GENERATION/index.tsv" || die 'could not initialize staged link-intake index'
  fi
}

existing_original_urls() {
  awk '
    /^Original URLs:$/ { seen=1; next }
    seen && /^- / { sub(/^- /, ""); print; next }
    seen { exit }
  ' "$1"
}

unique_original_urls() {
  local existing=$1 original=$2
  {
    [ -n "$existing" ] && [ -f "$existing" ] && existing_original_urls "$existing"
    printf '%s\n' "$original"
  } | LC_ALL=C sort -u
}

validate_record() {
  local record=$1 expected=${2:-} generation=$3
  local canonical normalized record_id expected_id source title summary terms transcript status originals claims failure retrieved original
  [ -f "$record" ] || die "record is absent: $record"
  record_id=$(sed -n 's/^Record ID: //p' "$record" | head -1)
  canonical=$(sed -n 's/^Canonical URL: //p' "$record" | head -1)
  source=$(sed -n 's/^Source type: //p' "$record" | head -1)
  title=$(sed -n 's/^Title: //p' "$record" | head -1)
  summary=$(sed -n 's/^Summary: //p' "$record" | head -1)
  terms=$(sed -n 's/^Search terms: //p' "$record" | head -1)
  transcript=$(sed -n 's/^Transcript: //p' "$record" | head -1)
  status=$(sed -n 's/^Retrieval status: //p' "$record" | head -1)
  failure=$(sed -n 's/^Failure: //p' "$record" | head -1)
  retrieved=$(sed -n 's/^Retrieved at: //p' "$record" | head -1)
  [ -n "$canonical" ] || die "record is missing canonical URL: $record"
  [ -z "$expected" ] || [ "$canonical" = "$expected" ] || die "record canonical URL does not match: $record"
  normalized=$(canonicalize_url "$canonical")
  [ "$canonical" = "$normalized" ] || die "record canonical URL is not normalized: $record"
  expected_id=$(record_id_for "$canonical")
  [ "$record_id" = "$expected_id" ] || die "record ID does not match canonical URL: $record"
  case "$source" in article|web|video|audio|document|image|other) ;; *) die "record source type is invalid: $record" ;; esac
  case "$status" in captured|inaccessible) ;; *) die "record status is invalid: $record" ;; esac
  require_one_line 'record title' "$title"
  require_one_line 'record summary' "$summary"
  require_one_line 'record search terms' "$terms"
  is_calendar_date "$retrieved" || die "record retrieval date is invalid: $record"
  [ -n "$transcript" ] || die "record is missing transcript metadata: $record"
  originals=$(existing_original_urls "$record")
  [ -n "$originals" ] || die "record has no original URL: $record"
  while IFS= read -r original; do
    canonicalize_url "$original" >/dev/null
  done <<EOF
$originals
EOF
  claims=$(awk '/^## Key claims or takeaways$/{seen=1; next} seen && /^- /{print; next} seen{exit}' "$record")
  [ -n "$claims" ] || die "record has no claims or takeaways: $record"
  case "$transcript" in
    'not applicable'|unavailable:*) ;;
    'stored at transcripts/'*) [ -f "$generation/${transcript#stored at }" ] || die "record transcript path is absent: $record" ;;
    *) die "record transcript metadata is invalid: $record" ;;
  esac
  case "$source" in
    video|audio)
      case "$transcript" in 'stored at transcripts/'*|unavailable:*) ;; *) die "media record has no transcript outcome: $record" ;; esac
      ;;
    *) [ "$transcript" = 'not applicable' ] || die "non-media record has transcript metadata: $record" ;;
  esac
  if [ "$status" = inaccessible ]; then
    [ -n "$failure" ] || die "inaccessible record has no failure reason: $record"
  fi
}

validate_index_record() {
  local generation=$1 record=$2 canonical=$3 id=$4 retrieved=$5 source=$6 title=$7 status=$8 terms=$9
  local record_id record_retrieved record_source record_title record_status record_terms expected_id
  expected_id=$(record_id_for "$canonical")
  [ "$id" = "$expected_id" ] || die "index record ID does not match canonical URL: $canonical"
  validate_record "$record" "$canonical" "$generation"
  record_id=$(sed -n 's/^Record ID: //p' "$record" | head -1)
  record_retrieved=$(sed -n 's/^Retrieved at: //p' "$record" | head -1)
  record_source=$(sed -n 's/^Source type: //p' "$record" | head -1)
  record_title=$(sed -n 's/^Title: //p' "$record" | head -1)
  record_status=$(sed -n 's/^Retrieval status: //p' "$record" | head -1)
  record_terms=$(sed -n 's/^Search terms: //p' "$record" | head -1)
  [ "$record_id" = "$id" ] \
    && [ "$record_retrieved" = "$retrieved" ] \
    && [ "$record_source" = "$source" ] \
    && [ "$record_title" = "$title" ] \
    && [ "$record_status" = "$status" ] \
    && [ "$record_terms" = "$terms" ] \
    || die "index metadata does not match record: $canonical"
}

VALIDATED_RECORD_COUNT=0

validate_state() {
  local generation=$1 index="$1/index.tsv" records="$1/records" history="$1/history" transcripts="$1/transcripts"
  local header canonical id retrieved source title status terms record path entry basename matches count=0 relative record_id
  [ -d "$records" ] || die "link-intake records directory is absent: $records"
  [ -d "$history" ] || die "link-intake history directory is absent: $history"
  [ -d "$transcripts" ] || die "link-intake transcripts directory is absent: $transcripts"
  [ -f "$index" ] || die "link-intake index is absent: $index"
  IFS= read -r header < "$index" || die "link-intake index is unreadable: $index"
  [ "$header" = $'canonical_url\trecord_id\tretrieved_at\tsource_type\ttitle\tstatus\tsearch_terms' ] \
    || die "link-intake index header is invalid: $index"
  awk -F '\t' '
    NR == 1 { next }
    NF != 7 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || $6 == "" || $7 == "" { exit 1 }
    seen_url[$1]++ || seen_id[$2]++ { exit 1 }
  ' "$index" || die "link-intake index rows are malformed or duplicated: $index"
  while IFS=$'\t' read -r canonical id retrieved source title status terms; do
    [ "$canonical" = canonical_url ] && continue
    record="$records/$id.md"
    validate_index_record "$generation" "$record" "$canonical" "$id" "$retrieved" "$source" "$title" "$status" "$terms"
    count=$((count + 1))
  done < "$index"
  [ "$count" -gt 0 ] || die 'link-intake index has no records'
  for path in "$records"/*; do
    [ -e "$path" ] || continue
    [ -f "$path" ] || die "unexpected entry in records directory: $path"
    basename=${path##*/}
    case "$basename" in *.md) ;; *) die "unexpected entry in records directory: $path" ;; esac
    id=${basename%.md}
    matches=$(awk -F '\t' -v id="$id" 'NR > 1 && $2 == id { count++ } END { print count + 0 }' "$index")
    [ "$matches" = 1 ] || die "record is absent from index: $path"
  done
  for path in "$history"/*; do
    [ -e "$path" ] || continue
    [ -d "$path" ] || die "unexpected entry in history directory: $path"
    id=${path##*/}
    for entry in "$path"/*; do
      [ -e "$entry" ] || continue
      [ -f "$entry" ] || die "unexpected entry in record history: $entry"
      basename=${entry##*/}
      case "$basename" in *.md) ;; *) die "unexpected entry in record history: $entry" ;; esac
      validate_record "$entry" '' "$generation"
      record_id=$(sed -n 's/^Record ID: //p' "$entry" | head -1)
      [ "$record_id" = "$id" ] || die "history record ID does not match directory: $entry"
    done
  done
  for path in "$transcripts"/*/*.txt; do
    [ -f "$path" ] || continue
    relative=${path#"$generation/"}
    matches=$(grep -R -F -l "Transcript: stored at $relative" "$records" "$history" 2>/dev/null | wc -l | tr -d ' ')
    [ "$matches" -gt 0 ] || die "transcript is absent from records and history: $path"
  done
  VALIDATED_RECORD_COUNT=$count
}

prepare_index() {
  local generation=$1 canonical=$2 id=$3 retrieved=$4 source=$5 title=$6 status=$7 terms=$8
  local index="$generation/index.tsv" tmp
  tmp=$(mktemp "$generation/.index.XXXXXX") || die 'could not create staged index update'
  {
    printf 'canonical_url\trecord_id\tretrieved_at\tsource_type\ttitle\tstatus\tsearch_terms\n'
    awk -F '\t' -v id="$id" 'NR > 1 && $2 != id { print }' "$index"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$canonical" "$id" "$retrieved" "$source" "$title" "$status" "$terms"
  } > "$tmp" || die 'could not write staged index update'
  mv "$tmp" "$index" || die 'could not install staged index update'
}

snapshot_existing_record() {
  local generation=$1 record=$2 id=$3
  local digest destination tmp previous_retrieved
  [ -f "$record" ] || return 0
  digest=$(sha256 < "$record")
  previous_retrieved=$(sed -n 's/^Retrieved at: //p' "$record" | head -1)
  destination="$generation/history/$id/${previous_retrieved}-${digest}.md"
  [ -f "$destination" ] && return 0
  mkdir -p "$generation/history/$id" || die 'could not initialize record history'
  tmp=$(mktemp "$generation/history/$id/.snapshot.XXXXXX") || die 'could not create record history snapshot'
  cp "$record" "$tmp" || die 'could not stage record history snapshot'
  mv "$tmp" "$destination" || die 'could not install staged record history snapshot'
}

copy_transcript() {
  local generation=$1 source=$2 id=$3
  local digest directory destination tmp
  [ -f "$source" ] || die "transcript file is absent: $source"
  digest=$(sha256 < "$source")
  directory="$generation/transcripts/$id"
  destination="$directory/$digest.txt"
  if [ ! -f "$destination" ]; then
    mkdir -p "$directory" || die 'could not initialize transcript storage'
    tmp=$(mktemp "$directory/.transcript.XXXXXX") || die 'could not create staged transcript'
    cp "$source" "$tmp" || die 'could not stage transcript'
    mv "$tmp" "$destination" || die 'could not install staged transcript'
  fi
  printf 'transcripts/%s/%s.txt\n' "$id" "$digest"
}

replace_symlink() {
  local source=$1 target=$2
  if mv --help 2>&1 | grep -F -q -- '--no-target-directory'; then
    mv -fT "$source" "$target"
  else
    mv -fh "$source" "$target"
  fi
}

publish_generation() {
  local target
  target="generations/${STAGED_GENERATION##*/}"
  STAGED_LINK=$(mktemp "$LINK_ROOT/.current.XXXXXX") || die 'could not create current-state switch'
  rm -f "$STAGED_LINK" || die 'could not prepare current-state switch'
  ln -s "$target" "$STAGED_LINK" || die 'could not prepare current-state target'
  replace_symlink "$STAGED_LINK" "$CURRENT_LINK" || die 'could not publish link-intake generation'
  STAGED_LINK=
  STAGED_GENERATION=
}

record_field() {
  local field=$1 record=$2
  sed -n "s/^$field: //p" "$record" | head -1
}

slugify() {
  printf '%s' "$1" |
    LC_ALL=C tr '[:upper:]' '[:lower:]' |
    LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//'
}

# The scout task id is derived from the canonical URL alone so that re-recording the
# same link - including the scout's own transcript-retaining upsert - converges on the
# one brief and backlog item instead of queueing a second scout under a changed title.
scout_task_id_for() {
  local canonical=$1 slug digest
  slug=$(slugify "$(url_host "$canonical")" | cut -c1-24 | LC_ALL=C sed -e 's/-*$//')
  [ -n "$slug" ] || slug='link'
  digest=$(record_id_for "$canonical" | cut -c1-8)
  printf 'ingest-%s-%s\n' "$slug" "$digest"
}

scout_error() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

scout_task_text() {
  local record=$1 canonical=$2 task_id=$3 data=$4
  local title summary source terms helper_q home_q canonical_q source_q source_file_q
  local lane_repo_q backlog_q success_command failure_command idea_command
  title=$(record_field Title "$record")
  summary=$(record_field Summary "$record")
  source=$(record_field 'Source type' "$record")
  terms=$(record_field 'Search terms' "$record")
  helper_q=$(shell_quote "$SCRIPT_DIR/fm-link-intake.sh")
  home_q=$(shell_quote "$FM_HOME")
  canonical_q=$(shell_quote "$canonical")
  source_q=$(shell_quote "$source")
  source_file_q=$(shell_quote "$data/$task_id/source.txt")
  lane_repo_q=$(shell_quote '<mapped-lane-repo>')
  backlog_q=$(shell_quote "$data/backlog.md")
  success_command="FM_HOME=$home_q $helper_q upsert --url $canonical_q --source-type $source_q --title '<title>' --summary '<summary>' --terms '<terms>' --claim '<claim>' --transcript-file $source_file_q --no-scout"
  failure_command="FM_HOME=$home_q $helper_q upsert --url $canonical_q --source-type $source_q --failure '<reason>' --no-scout"
  idea_command="tasks-axi add '<slug-id>' '<title>' --kind ship --repo $lane_repo_q --queue --file $backlog_q --body $(shell_quote "from $task_id: <one line>; see $data/$task_id/report.md")"
  cat <<EOF
Ingest scout for a link the captain sent: $title

- Source: $canonical
- Source type: $source
- Recorded summary: $summary
- Recorded search terms: $terms
- Link-intake record: $(logical_record_path_for "$canonical")

Do these three things, in order.

1. Ingest the source with the existing tool suited to it: \`chrome-devtools-axi\` for
   pages and documents, the existing media transcript tooling for video or audio.
   Store the full ingested text as a durable artifact at \`$data/$task_id/source.txt\`.
   That file survives cleanup alongside the report, so every claim in the report must be
   traceable to it; never leave the only copy in a temporary directory.
   For video or audio, also retain it in the searchable record:
   \`$success_command\`
   Keep the existing title, summary, terms, and claims unless the ingest corrects them.
   If the source cannot be retrieved, record the visible failure with
   \`$failure_command\`
   and report what you tried; do not guess at the content.

2. Write the report at \`$data/$task_id/report.md\`, citing the stored artifact for
   every factual claim about the source. Cover these four sections:
   - **What we can build from it** - concrete, buildable things, each mapped to a current
     lane in \`$data/projects.md\` and the captain's working doctrine in \`$data/captain.md\`.
   - **Out-of-the-box ideas** - angles the source does not state outright but that its
     material genuinely supports.
   - **Potential blindspots** - what the source omits, overstates, or gets wrong, and
     where following it would cost us.
   - **Other angles worth taking** - adjacent framings, and lanes this does not fit.
   Keep what the source actually says separate from what you recommend, and leave out
   anything the artifact does not support.

3. File each promising idea as its own queued backlog item, one per idea:
   \`$idea_command\`
   Replace \`<mapped-lane-repo>\` with the repository for the current lane that idea is mapped to in the report.
   Use \`--kind scout\` for an idea that still needs investigation before it can ship.
   Queue them only. Never start, dispatch, promote, or spawn anything, and never edit a
   project: firstmate decides what gets worked and when. List every item you filed in
   the report so the queue and the report agree.
EOF
}

specialize_link_intake_brief() {
  local brief=$1 task_id=$2 data=$3 directory tmp
  directory=${brief%/*}
  tmp=$(mktemp "$directory/.brief-contract.XXXXXX") || return 1
  if ! awk -v task_dir="$data/$task_id/" -v status="$FM_HOME/state/$task_id.status" \
    -v helper="$SCRIPT_DIR/fm-link-intake.sh" -v home="$FM_HOME" -v backlog="$data/backlog.md" '
    $0 == "The report is the only thing that survives, so anything worth keeping must be in it." {
      print "The durable source artifacts, report, link-intake record, and queued backlog items survive teardown."
      print "Scratch work in the disposable worktree does not."
      next
    }
    $0 == "2. Stay inside this worktree; the only files you may write outside it are the report and the status file below." {
      print "2. Stay inside this worktree except for the authoritative-home outputs named below."
      print "   Outside it, you may write only under `" task_dir "`, the status file `" status "`, link-intake record updates performed through `" helper "` with explicit `FM_HOME=" home "`, and queued backlog items filed through `tasks-axi` in `" backlog "`."
      print "   Every other file must stay inside the disposable worktree."
      next
    }
    { print }
  ' "$brief" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$brief" || { rm -f "$tmp"; return 1; }
}

fill_brief_task() {
  local brief=$1 task=$2 directory tmp
  directory=${brief%/*}
  tmp=$(mktemp "$directory/.brief.XXXXXX") || return 1
  if ! awk -v taskfile="$task" '
    $0 == "# Task" {
      print
      while ((getline line < taskfile) > 0) print line
      close(taskfile)
      replaced = 1
      replacing = 1
      next
    }
    replacing && /^# Herdr / {
      print ""
      replacing = 0
      print
      next
    }
    replacing { next }
    { print }
    END { if (!replaced || replacing) exit 1 }
  ' "$brief" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$brief" || { rm -f "$tmp"; return 1; }
}

file_scout_backlog_item() {
  local task_id=$1 title=$2 canonical=$3 brief=$4 data=$5 repo=$6
  local backlog output
  backlog="$data/backlog.md"
  if fm_backlog_backend_manual "$FM_HOME/config"; then
    printf 'manual backlog: add queued scout item %s "Ingest: %s" for %s to %s with repo %s\n' \
      "$task_id" "$title" "$canonical" "$backlog" "$repo"
    return 0
  fi
  if ! fm_tasks_axi_backend_available "$FM_HOME/config"; then
    scout_error 'the configured tasks-axi backlog backend is unavailable or incompatible'
    return 1
  fi
  if tasks-axi show "$task_id" --file "$backlog" >/dev/null 2>&1; then
    output=$(tasks-axi update "$task_id" --repo "$repo" --file "$backlog" 2>&1) \
      || { scout_error "could not repair the ingest scout backlog repository: $output"; return 1; }
  else
    output=$(tasks-axi add "$task_id" "Ingest: $title" --kind scout --repo "$repo" --queue --file "$backlog" \
      --body "queued by link intake for $canonical; brief $brief; report $data/$task_id/report.md" 2>&1) \
      || { scout_error "could not file the queued ingest scout backlog item: $output"; return 1; }
  fi
  printf 'scout backlog: %s queued in %s\n' "$task_id" "$backlog"
}

prepare_scout() {
  local generation=$1 canonical=$2 repo=$3
  local id record status title task_id data brief output task_tmp
  id=$(record_id_for "$canonical")
  record="$generation/records/$id.md"
  if [ ! -f "$record" ]; then
    scout_error "link record is absent: $canonical"
    return 1
  fi
  status=$(record_field 'Retrieval status' "$record")
  if [ "$status" != captured ]; then
    scout_error "an inaccessible link record has nothing to ingest: $canonical"
    return 1
  fi
  title=$(record_field Title "$record")
  task_id=$(scout_task_id_for "$canonical")
  data="$FM_HOME/data"
  brief="$data/$task_id/brief.md"
  if [ ! -f "$brief" ]; then
    output=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-brief.sh" "$task_id" "$repo" --scout 2>&1) \
      || { scout_error "could not scaffold the ingest scout brief: $output"; return 1; }
  fi
  specialize_link_intake_brief "$brief" "$task_id" "$data" \
    || { scout_error 'could not apply the link-intake scout write contract'; return 1; }
  task_tmp=$(mktemp "$data/$task_id/.task.XXXXXX") \
    || { scout_error 'could not stage the ingest scout task text'; return 1; }
  if ! scout_task_text "$record" "$canonical" "$task_id" "$data" > "$task_tmp"; then
    rm -f "$task_tmp"
    scout_error 'could not write the ingest scout task text'
    return 1
  fi
  if ! fill_brief_task "$brief" "$task_tmp"; then
    rm -f "$task_tmp"
    scout_error 'could not fill the ingest scout brief'
    return 1
  fi
  rm -f "$task_tmp"
  grep -F -x -q '{TASK}' "$brief" \
    && { scout_error "the ingest scout brief still has an unfilled task: $brief"; return 1; }
  grep -F -q "$canonical" "$brief" \
    || { scout_error "the ingest scout brief does not name its source link: $brief"; return 1; }
  grep -F -q "Outside it, you may write only under \`$data/$task_id/\`" "$brief" \
    || { scout_error "the ingest scout brief lacks its authoritative-home write contract: $brief"; return 1; }
  file_scout_backlog_item "$task_id" "$title" "$canonical" "$brief" "$data" "$repo" || return 1
  printf 'scout: %s prepared, not dispatched\n' "$task_id"
  printf 'scout brief: %s\n' "$brief"
}

command_prepare_scout() {
  local canonical='' original='' repo=$SCOUT_REPO_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) shift; original=${1:-} ;;
      --scout-repo) shift; repo=${1:-} ;;
      -h|--help|help) usage; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    [ "$#" -gt 0 ] || die 'missing value for option'
    shift
  done
  require_one_line URL "$original"
  require_one_line 'scout repo' "$repo"
  canonical=$(canonicalize_url "$original") || return $?
  acquire_lock
  resolve_current || die 'link-intake current state is absent'
  prune_abandoned_generations "$CURRENT_GENERATION"
  validate_state "$CURRENT_GENERATION"
  prepare_scout "$CURRENT_GENERATION" "$canonical" "$repo" || return 2
}

command_upsert() {
  local original='' canonical='' canonical_input='' source='' title='' summary='' terms='' retrieved='' transcript_file='' transcript_unavailable='' failure='' argument claim
  local claims='' id current='' record existing transcript note status host path record_tmp logical_record
  local scout=1 scout_repo=$SCOUT_REPO_DEFAULT published repair_command
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) shift; original=${1:-} ;;
      --canonical-url) shift; canonical_input=${1:-} ;;
      --source-type) shift; source=${1:-} ;;
      --title) shift; title=${1:-} ;;
      --summary) shift; summary=${1:-} ;;
      --terms) shift; terms=${1:-} ;;
      --claim) shift; claim=${1:-}; require_one_line claim "$claim"; claims="${claims}${claims:+$'\n'}$claim" ;;
      --retrieved-at) shift; retrieved=${1:-} ;;
      --transcript-file) shift; transcript_file=${1:-} ;;
      --transcript-unavailable) shift; transcript_unavailable=${1:-} ;;
      --failure) shift; failure=${1:-} ;;
      --no-scout) scout=0 ;;
      --scout-repo) shift; scout_repo=${1:-} ;;
      -h|--help|help) usage; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    [ "$#" -gt 0 ] || die 'missing value for option'
    shift
  done
  require_one_line URL "$original"
  canonical=$(canonicalize_url "${canonical_input:-$original}") || return $?
  [ -z "$canonical_input" ] || require_one_line 'canonical URL' "$canonical_input"
  case "$source" in article|web|video|audio|document|image|other) ;; *) die 'source type must be article, web, video, audio, document, image, or other' ;; esac
  if [ -n "$retrieved" ]; then
    is_calendar_date "$retrieved" || die 'retrieved-at must be a real YYYY-MM-DD calendar date'
  else
    retrieved=$(date -u +%F)
  fi
  require_one_line 'retrieved-at' "$retrieved"
  if [ -n "$failure" ]; then
    require_one_line failure "$failure"
    status=inaccessible
    [ -n "$title" ] || title=Unavailable
    [ -n "$summary" ] || summary="Retrieval failed: $failure"
    [ -n "$claims" ] || claims="Could not retrieve the source: $failure"
    [ -n "$terms" ] || { host=$(url_host "$canonical"); terms="inaccessible,$host"; }
  else
    status=captured
  fi
  require_one_line title "$title"
  require_one_line summary "$summary"
  require_one_line 'search terms' "$terms"
  [ -n "$claims" ] || die 'at least one --claim is required unless --failure is given'
  [ -z "$transcript_file" ] || [ -z "$transcript_unavailable" ] || die 'provide either transcript-file or transcript-unavailable, not both'
  case "$source" in
    video|audio)
      if [ -z "$transcript_file" ]; then
        if [ -z "$transcript_unavailable" ] && [ -n "$failure" ]; then
          transcript_unavailable=$failure
        fi
        require_one_line 'transcript-unavailable reason' "$transcript_unavailable"
      else
        [ -f "$transcript_file" ] || die "transcript file is absent: $transcript_file"
      fi
      ;;
    *)
      [ -z "$transcript_file" ] || die 'transcript-file is only supported for video or audio records'
      [ -z "$transcript_unavailable" ] || die 'transcript-unavailable is only supported for video or audio records'
      ;;
  esac
  acquire_lock
  if resolve_current; then
    current=$CURRENT_GENERATION
    validate_state "$current"
  fi
  prune_abandoned_generations "$current"
  create_staged_generation "$current"
  id=$(record_id_for "$canonical")
  record="$STAGED_GENERATION/records/$id.md"
  existing=$record
  case "$source" in
    video|audio)
      if [ -n "$transcript_file" ]; then
        transcript=$(copy_transcript "$STAGED_GENERATION" "$transcript_file" "$id") || return $?
        note="stored at $transcript"
      else
        note="unavailable: $transcript_unavailable"
      fi
      ;;
    *) note='not applicable' ;;
  esac
  record_tmp=$(mktemp "$STAGED_GENERATION/records/.record.XXXXXX") || die 'could not create staged record update'
  {
    printf '# Link intake record\n\n'
    printf 'Record ID: %s\n' "$id"
    printf 'Canonical URL: %s\n' "$canonical"
    printf 'Original URLs:\n'
    unique_original_urls "$existing" "$original" | while IFS= read -r argument; do printf '%s\n' "- $argument"; done
    printf 'Retrieved at: %s\n' "$retrieved"
    printf 'Retrieval status: %s\n' "$status"
    printf 'Source type: %s\n' "$source"
    printf 'Title: %s\n' "$title"
    printf 'Summary: %s\n' "$summary"
    printf 'Search terms: %s\n' "$terms"
    printf 'Transcript: %s\n' "$note"
    printf 'Failure: %s\n\n' "${failure:-none}"
    printf '## Key claims or takeaways\n'
    printf '%s\n' "$claims" | while IFS= read -r argument; do printf '%s\n' "- $argument"; done
  } > "$record_tmp" || die 'could not write staged record update'
  validate_record "$record_tmp" "$canonical" "$STAGED_GENERATION"
  if [ -f "$record" ] && ! cmp -s "$record" "$record_tmp"; then
    snapshot_existing_record "$STAGED_GENERATION" "$record" "$id"
  fi
  mv "$record_tmp" "$record" || die 'could not install staged record update'
  prepare_index "$STAGED_GENERATION" "$canonical" "$id" "$retrieved" "$source" "$title" "$status" "$terms"
  validate_state "$STAGED_GENERATION"
  published=$STAGED_GENERATION
  publish_generation
  logical_record=$(logical_record_path_for "$canonical")
  printf '%s\n' "$logical_record"
  if [ "$scout" = 1 ] && [ "$status" = captured ]; then
    require_one_line 'scout repo' "$scout_repo"
    if ! prepare_scout "$published" "$canonical" "$scout_repo"; then
      repair_command="FM_HOME=$(shell_quote "$FM_HOME") $(shell_quote "$SCRIPT_DIR/fm-link-intake.sh") prepare-scout --url $(shell_quote "$canonical") --scout-repo $(shell_quote "$scout_repo")"
      printf 'error: the link record is stored, but its ingest scout was not prepared; rerun: %s\n' \
        "$repair_command" >&2
      return 3
    fi
  fi
}

command_validate() {
  local target=${1:-} canonical record
  [ "$#" -eq 1 ] || die 'validate accepts one URL or --all'
  acquire_lock
  resolve_current || die 'link-intake current state is absent'
  prune_abandoned_generations "$CURRENT_GENERATION"
  validate_state "$CURRENT_GENERATION"
  if [ "$target" = --all ]; then
    printf 'valid: %s records\n' "$VALIDATED_RECORD_COUNT"
    return 0
  fi
  canonical=$(canonicalize_url "$target") || return $?
  record="$CURRENT_GENERATION/records/$(record_id_for "$canonical").md"
  validate_record "$record" "$canonical" "$CURRENT_GENERATION"
  printf 'valid: %s\n' "$(logical_record_path_for "$canonical")"
}

main() {
  case "${1:-}" in
    upsert) shift; command_upsert "$@" ;;
    prepare-scout) shift; command_prepare_scout "$@" ;;
    validate) shift; command_validate "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
