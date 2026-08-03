#!/usr/bin/env bash
# fm-specgraph-capture.sh - validate and atomically publish private SpecGraph snapshots.
#
# Captures conservative semantic drafts at existing firstmate durable write
# points.
# Every node and edge carries an epistemic level and source references.
# Inference input remains INFERRED even when its supporting file exists; only
# explicit captain decisions and filed evidence can produce CONFIRMED records.
# Missing or unreadable material produces a schema-valid INCOMPLETE snapshot
# with UNKNOWN records rather than being omitted or invented.
#
# Output defaults to $FM_HOME/data/specgraph and is private, mode 0600.
# Files sort by a monotonic sequence before capture time and event identity.
# Repeating the same event, subject, sources, relations, and inference bytes is
# idempotent and returns the existing snapshot path.
#
# Usage:
#   fm-specgraph-capture.sh capture --event <event> --subject <id> \
#     [--source <path>]... [--related <id>]... [--inference <text>]... \
#     [--baseline-id <id>] [--effective-at <ISO-8601>]
#   fm-specgraph-capture.sh validate <snapshot.json>
#
# Events: task-completed, decision-resolved, captain-framework-correction,
# milestone-pr-merged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OUT_DIR="${FM_SPECGRAPH_DIR_OVERRIDE:-$DATA/specgraph}"
SCHEMA_VERSION=specgraph.snapshot.v0.1

fail() {
  printf 'fm-specgraph-capture: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

validate_slug() {
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._:-]*) fail "$label must be a non-empty privacy-safe identifier: $value" ;;
  esac
}

validate_event() {
  case "$1" in
    task-completed|decision-resolved|captain-framework-correction|milestone-pr-merged) ;;
    *) fail "unsupported event: $1" ;;
  esac
}

validate_time() {
  case "$1" in
    ????-??-??T??:??:??Z|????-??-??T??:??:??[+-]??:??) ;;
    *) fail "effective-at must be an ISO-8601 second timestamp" ;;
  esac
}

json_array_hash() {
  jq -cS "$2" "$1" | sha256_stdin
}

validate_structure() {
  jq -e --arg schema "$SCHEMA_VERSION" '
    def level: . == "CONFIRMED" or . == "INFERRED" or . == "UNKNOWN";
    def authority:
      . == "CAPTAIN" or . == "FILED_EVIDENCE" or . == "ADVISORY" or . == "UNKNOWN";
    def source_ref:
      type == "object"
      and (.kind | type == "string" and length > 0)
      and (.locator | type == "string" and length > 0)
      and ((.sha256 == null) or (.sha256 | test("^[0-9a-f]{64}$")));
    def epistemic:
      type == "object"
      and (.level | level)
      and (.sourceRefs | type == "array" and length > 0 and all(.[]; source_ref));
    def confirmed_authority:
      if .epistemic.level == "CONFIRMED"
      then (.authority == "CAPTAIN" or .authority == "FILED_EVIDENCE")
      else true
      end;
    def sha: type == "string" and test("^[0-9a-f]{64}$");
    .schemaVersion == $schema
    and (.sequence | type == "number" and floor == . and . >= 1)
    and (.snapshotId | type == "string" and length > 0)
    and (.baselineId | type == "string" and length > 0)
    and ((.parent == null) or (.parent | type == "string" and length > 0))
    and (.effectiveAt | type == "string" and length > 0)
    and (.capturedAt | type == "string" and length > 0)
    and (.authorityCompleteness == "COMPLETE"
      or .authorityCompleteness == "PARTIAL"
      or .authorityCompleteness == "UNKNOWN")
    and (.status == "COMPLETE" or .status == "INCOMPLETE")
    and (.incompleteReasons | type == "array" and all(.[]; type == "string" and length > 0))
    and (if .status == "INCOMPLETE" then (.incompleteReasons | length > 0)
      else (.incompleteReasons | length == 0) end)
    and (.setHashes.nodeSetSha256 | sha)
    and (.setHashes.edgeSetSha256 | sha)
    and (.setHashes.decisionSetSha256 | sha)
    and (.setHashes.specSetSha256 | sha)
    and (.setHashes.artifactSetSha256 | sha)
    and (.actor | type == "object")
    and (.actor.kind == "human" or .actor.kind == "model" or .actor.kind == "unknown")
    and (.actor.authority | authority)
    and (.actor.independence == "INDEPENDENT"
      or .actor.independence == "NOT_INDEPENDENT"
      or .actor.independence == "UNKNOWN")
    and (.trigger | type == "object")
    and (.trigger.type | type == "string" and length > 0)
    and (.trigger.subjectId | type == "string" and length > 0)
    and (.trigger.idempotencyKey | sha)
    and (.trigger.sourceRefs | type == "array" and length > 0 and all(.[]; source_ref))
    and (.nodes | type == "array" and length > 0)
    and ([.nodes[].id] | length == (unique | length))
    and (.nodes | all(.[];
      (.id | type == "string" and length > 0)
      and (.type == "Goal" or .type == "Decision" or .type == "Spec"
        or .type == "Component" or .type == "WorkflowMap" or .type == "Task"
        or .type == "Artifact" or .type == "Evidence" or .type == "Assumption"
        or .type == "Claim" or .type == "ReviewAssertion" or .type == "Capability"
        or .type == "Gate" or .type == "Gap" or .type == "Snapshot")
      and (.revision | type == "number" and floor == . and . >= 1)
      and (.label | type == "string" and length > 0)
      and (.status | type == "string" and length > 0)
      and (.scope | type == "string" and length > 0)
      and (.authority | authority)
      and (.epistemic | epistemic)
      and confirmed_authority))
    and ([.nodes[] | select(.type == "Snapshot")] | length >= 1)
    and (.edges | type == "array")
    and ([.edges[].id] | length == (unique | length))
    and (.edges | all(.[];
      (.id | type == "string" and length > 0)
      and (.from | type == "string" and length > 0)
      and (.to | type == "string" and length > 0)
      and (.predicate == "motivated" or .predicate == "defines"
        or .predicate == "decomposes_to" or .predicate == "implemented_by"
        or .predicate == "verified_by" or .predicate == "supersedes"
        or .predicate == "blocked_by" or .predicate == "blocks"
        or .predicate == "belongs_to"
        or .predicate == "supports" or .predicate == "refutes"
        or .predicate == "reviews" or .predicate == "challenges"
        or .predicate == "validates" or .predicate == "adopts"
        or .predicate == "rejects" or .predicate == "invalidates"
        or .predicate == "governs" or .predicate == "guards"
        or .predicate == "derived_from" or .predicate == "valid_in"
        or .predicate == "preserved_as_lineage")
      and (.scope | type == "string" and length > 0)
      and (.authority | authority)
      and (.epistemic | epistemic)
      and confirmed_authority
      and (if .predicate == "supersedes"
        then (.supersession != null
          and (.supersession.mode == "full" or .supersession.mode == "partial")
          and (.supersession.reason | type == "string" and length > 0))
        else (.supersession == null)
        end)))
    and (([.nodes[].id] | unique) as $ids
      | .edges | all(.[]; (.from as $from | $ids | index($from)) != null
        and (.to as $to | $ids | index($to)) != null))
    and (.snapshotId as $snapshot_id
      | [.nodes[] | select(.id == ("snapshot:" + $snapshot_id))][0] as $snapshot
      | $snapshot.id == ("snapshot:" + .snapshotId)
      and $snapshot.properties.baselineId == .baselineId
      and $snapshot.properties.parent == .parent
      and $snapshot.properties.effectiveAt == .effectiveAt
      and $snapshot.properties.capturedAt == .capturedAt
      and $snapshot.properties.setHashes == .setHashes
      and $snapshot.properties.authorityCompleteness == .authorityCompleteness
      and $snapshot.properties.status == .status)
  ' "$1" >/dev/null
}

command_validate() {
  local file=$1 node_hash edge_hash decision_hash spec_hash artifact_hash
  [ -f "$file" ] && [ ! -L "$file" ] || fail "snapshot is not a regular file: $file"
  require_jq
  validate_structure "$file" || fail "snapshot does not satisfy $SCHEMA_VERSION"
  node_hash=$(json_array_hash "$file" '[.nodes[] | select(.type != "Snapshot")]')
  edge_hash=$(json_array_hash "$file" '.edges')
  decision_hash=$(json_array_hash "$file" '[.nodes[] | select(.type == "Decision")]')
  spec_hash=$(json_array_hash "$file" '[.nodes[] | select(.type == "Spec")]')
  artifact_hash=$(json_array_hash "$file" '[.nodes[] | select(.type == "Artifact")]')
  [ "$(jq -r '.setHashes.nodeSetSha256' "$file")" = "$node_hash" ] \
    || fail "node set hash mismatch"
  [ "$(jq -r '.setHashes.edgeSetSha256' "$file")" = "$edge_hash" ] \
    || fail "edge set hash mismatch"
  [ "$(jq -r '.setHashes.decisionSetSha256' "$file")" = "$decision_hash" ] \
    || fail "decision set hash mismatch"
  [ "$(jq -r '.setHashes.specSetSha256' "$file")" = "$spec_hash" ] \
    || fail "spec set hash mismatch"
  [ "$(jq -r '.setHashes.artifactSetSha256' "$file")" = "$artifact_hash" ] \
    || fail "artifact set hash mismatch"
  printf 'valid: %s\n' "$file"
}

source_kind() {
  local event=$1 path=$2 base
  base=$(basename "$path")
  case "$event:$base" in
    decision-resolved:*|captain-framework-correction:*) printf '%s\n' captain-decision ;;
    milestone-pr-merged:*.pr-poll-retirement) printf '%s\n' runtime-receipt ;;
    *:*.meta) printf '%s\n' task-metadata ;;
    *:supervisor-readback.md) printf '%s\n' supervisor-readback ;;
    *:report.md) printf '%s\n' report ;;
    *) printf '%s\n' file ;;
  esac
}

append_node() {
  jq -cn \
    --arg id "$2" --arg type "$3" --arg label "$4" --arg status "$5" \
    --arg scope "$6" --arg authority "$7" --arg level "$8" \
    --slurpfile refs "$9" --argjson properties "${10}" \
    '{id:$id,type:$type,revision:1,label:$label,status:$status,scope:$scope,
      authority:$authority,epistemic:{level:$level,sourceRefs:$refs[0]},properties:$properties}' \
    >> "$1"
}

append_edge() {
  jq -cn \
    --arg id "$2" --arg from "$3" --arg predicate "$4" --arg to "$5" \
    --arg scope "$6" --arg authority "$7" --arg level "$8" --slurpfile refs "$9" \
    '{id:$id,from:$from,predicate:$predicate,to:$to,scope:$scope,
      authority:$authority,epistemic:{level:$level,sourceRefs:$refs[0]},supersession:null}' \
    >> "$1"
}

read_meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

capture_cleanup() {
  [ -z "${tmp_root:-}" ] || rm -rf "$tmp_root"
  if [ -n "${lock:-}" ]; then
    rm -f "$lock/pid" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
  fi
}

capture_lock_stale() {
  local dir=$1 pid mtime now
  [ -d "$dir" ] || return 1
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$pid" 2>/dev/null && return 1; return 0 ;;
  esac
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$dir" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$dir" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - mtime)) -ge 900 ]
}

capture_lock_acquire() {
  local dir=$1 stale
  if ! mkdir "$dir" 2>/dev/null; then
    capture_lock_stale "$dir" || fail "capture lock is busy: $dir"
    stale="$dir.stale.$$"
    if mv "$dir" "$stale" 2>/dev/null; then
      rm -rf "$stale"
    fi
    mkdir "$dir" 2>/dev/null || fail "capture lock is busy: $dir"
  fi
  lock=$dir
  printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
}

command_capture() {
  local event='' subject='' baseline_id='' effective_at='' related inference
  local captured_at compact key key_short source_fingerprint='' existing source_count=0 missing_count=0
  local lock sequence previous_file='' parent=null parent_json snapshot_id filename tmp_root refs_ndjson refs_json
  local nodes_ndjson nodes_json edges_ndjson edges_json reasons_ndjson reasons_json
  local node_hash edge_hash decision_hash spec_hash artifact_hash primary_type primary_label
  local primary_level primary_authority actor_kind=unknown actor_harness='' actor_model='' actor_effort=''
  local actor_role=unknown actor_authority=UNKNOWN actor_independence=UNKNOWN meta_file='' path digest kind
  local primary_id evidence_id snapshot_node_id claim_id artifact_id i=0 edge_i=0 status=INCOMPLETE
  local authority_completeness=UNKNOWN final_tmp sequence_tmp
  local -a sources related_ids inferences
  sources=()
  related_ids=()
  inferences=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event) shift; event=${1:-} ;;
      --subject) shift; subject=${1:-} ;;
      --source) shift; sources+=("${1:-}") ;;
      --related) shift; related=${1:-}; validate_slug related "$related"; related_ids+=("$related") ;;
      --inference) shift; inference=${1:-}; [ -n "$inference" ] || fail "inference must not be empty"; inferences+=("$inference") ;;
      --baseline-id) shift; baseline_id=${1:-}; validate_slug baseline-id "$baseline_id" ;;
      --effective-at) shift; effective_at=${1:-}; validate_time "$effective_at" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_event "$event"
  validate_slug subject "$subject"
  require_jq

  captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  compact=$(date -u +%Y%m%dT%H%M%SZ)
  [ -n "$effective_at" ] || effective_at=$captured_at

  tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-specgraph.XXXXXX") || fail "could not create temp directory"
  refs_ndjson="$tmp_root/refs.ndjson"
  refs_json="$tmp_root/refs.json"
  nodes_ndjson="$tmp_root/nodes.ndjson"
  nodes_json="$tmp_root/nodes.json"
  edges_ndjson="$tmp_root/edges.ndjson"
  edges_json="$tmp_root/edges.json"
  reasons_ndjson="$tmp_root/reasons.ndjson"
  reasons_json="$tmp_root/reasons.json"
  : > "$refs_ndjson"
  : > "$nodes_ndjson"
  : > "$edges_ndjson"
  : > "$reasons_ndjson"
  trap capture_cleanup EXIT
  trap 'capture_cleanup; exit 1' HUP INT TERM

  for path in "${sources[@]+"${sources[@]}"}"; do
    [ -n "$path" ] || fail "source path must not be empty"
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      digest=$(sha256_file "$path")
      kind=$(source_kind "$event" "$path")
      jq -cn --arg kind "$kind" --arg locator "$path" --arg sha256 "$digest" \
        '{kind:$kind,locator:$locator,sha256:$sha256}' >> "$refs_ndjson"
      source_fingerprint="${source_fingerprint}${source_fingerprint:+|}$path:$digest"
      source_count=$((source_count + 1))
      case "$path" in *.meta) [ -n "$meta_file" ] || meta_file=$path ;; esac
    else
      jq -cn --arg locator "$path" '{kind:"absence",locator:$locator,sha256:null}' >> "$refs_ndjson"
      jq -cn --arg reason "source is missing, unreadable, or a symlink: $path" '$reason' >> "$reasons_ndjson"
      source_fingerprint="${source_fingerprint}${source_fingerprint:+|}$path:UNKNOWN"
      missing_count=$((missing_count + 1))
    fi
  done
  if [ "${#sources[@]}" -eq 0 ]; then
    jq -cn --arg locator "event:$event:$subject" \
      '{kind:"absence",locator:$locator,sha256:null}' >> "$refs_ndjson"
    jq -cn --arg reason "no filed source was provided for $event" '$reason' >> "$reasons_ndjson"
    source_fingerprint=NO_SOURCE
  fi
  jq -s '.' "$refs_ndjson" > "$refs_json"

  for related in "${related_ids[@]+"${related_ids[@]}"}"; do
    source_fingerprint="$source_fingerprint|related:$related"
  done
  for inference in "${inferences[@]+"${inferences[@]}"}"; do
    digest=$(printf '%s' "$inference" | sha256_stdin)
    source_fingerprint="$source_fingerprint|inference:$digest"
  done
  key=$(printf '%s|%s|%s' "$event" "$subject" "$source_fingerprint" | sha256_stdin)
  key_short=$(printf '%s' "$key" | cut -c1-12)

  umask 077
  if [ -e "$OUT_DIR" ] && { [ ! -d "$OUT_DIR" ] || [ -L "$OUT_DIR" ]; }; then
    fail "output path is not a private directory: $OUT_DIR"
  fi
  mkdir -p "$OUT_DIR" || fail "could not create output directory: $OUT_DIR"
  chmod 0700 "$OUT_DIR" || fail "could not make output directory private"
  existing=$(find "$OUT_DIR" -maxdepth 1 -type f -name "*-$key_short.json" -print 2>/dev/null \
    | LC_ALL=C sort | head -1 || true)
  if [ -n "$existing" ]; then
    command_validate "$existing" >/dev/null
    printf '%s\n' "$existing"
    capture_cleanup
    trap - EXIT HUP INT TERM
    return 0
  fi

  capture_lock_acquire "$OUT_DIR/.capture.lock"
  existing=$(find "$OUT_DIR" -maxdepth 1 -type f -name "*-$key_short.json" -print 2>/dev/null \
    | LC_ALL=C sort | head -1 || true)
  if [ -n "$existing" ]; then
    command_validate "$existing" >/dev/null
    printf '%s\n' "$existing"
    capture_cleanup
    trap - EXIT HUP INT TERM
    return 0
  fi

  sequence=0
  if [ -e "$OUT_DIR/.sequence" ]; then
    [ -f "$OUT_DIR/.sequence" ] && [ ! -L "$OUT_DIR/.sequence" ] \
      || fail "sequence record is unsafe"
    sequence=$(cat "$OUT_DIR/.sequence")
    case "$sequence" in ''|*[!0-9]*) fail "sequence record is invalid" ;; esac
  else
    for existing in "$OUT_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.json; do
      [ -f "$existing" ] && [ ! -L "$existing" ] || continue
      existing=${existing##*/}
      existing=$((10#${existing%%-*}))
      [ "$existing" -le "$sequence" ] || sequence=$existing
    done
  fi
  sequence=$((sequence + 1))
  sequence_tmp="$OUT_DIR/.sequence.tmp.$$"
  printf '%s\n' "$sequence" > "$sequence_tmp"
  chmod 0600 "$sequence_tmp"
  mv -f "$sequence_tmp" "$OUT_DIR/.sequence"

  previous_file=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null \
    | LC_ALL=C sort | tail -1 || true)
  if [ -n "$previous_file" ]; then
    parent=$(jq -r '.snapshotId // empty' "$previous_file" 2>/dev/null || true)
    [ -n "$parent" ] || parent=null
  fi
  if [ -z "$baseline_id" ]; then
    if [ -n "$previous_file" ]; then
      baseline_id=$(jq -r '.baselineId // empty' "$previous_file" 2>/dev/null || true)
    fi
    [ -n "$baseline_id" ] || baseline_id=UNKNOWN
  fi
  if [ "$parent" = null ]; then
    parent_json=null
  else
    parent_json=$(jq -cn --arg parent "$parent" '$parent')
  fi
  snapshot_id="sgs-$(printf '%012d' "$sequence")-$key_short"
  snapshot_node_id="snapshot:$snapshot_id"

  if [ "$source_count" -gt 0 ]; then
    primary_level=CONFIRMED
    authority_completeness=PARTIAL
    case "$event" in
      decision-resolved|captain-framework-correction)
        primary_authority=CAPTAIN
        actor_kind=human
        actor_role=captain
        actor_authority=CAPTAIN
        ;;
      *)
        primary_authority=FILED_EVIDENCE
        actor_authority=FILED_EVIDENCE
        ;;
    esac
  else
    primary_level=UNKNOWN
    primary_authority=UNKNOWN
  fi
  if [ -n "$meta_file" ]; then
    actor_harness=$(read_meta_field "$meta_file" harness)
    actor_model=$(read_meta_field "$meta_file" model)
    actor_effort=$(read_meta_field "$meta_file" effort)
    actor_role=$(read_meta_field "$meta_file" kind)
    [ -n "$actor_role" ] || actor_role=unknown
    if [ -n "$actor_harness" ] || [ -n "$actor_model" ]; then
      actor_kind=model
    fi
  fi

  case "$event" in
    task-completed)
      primary_type=Task
      primary_label="Task completed: $subject"
      ;;
    decision-resolved)
      primary_type=Decision
      primary_label="Captain decision resolved: $subject"
      ;;
    captain-framework-correction)
      primary_type=Decision
      primary_label="Captain framework correction: $subject"
      ;;
    milestone-pr-merged)
      primary_type=Task
      primary_label="PR merged milestone: $subject"
      ;;
  esac
  primary_id="$(printf '%s' "$primary_type" | tr '[:upper:]' '[:lower:]'):$subject"
  evidence_id="evidence:$event:$key_short"
  append_node "$nodes_ndjson" "$primary_id" "$primary_type" "$primary_label" \
    "$([ "$primary_level" = CONFIRMED ] && printf ACTIVE || printf UNKNOWN)" \
    "$event:$subject" "$primary_authority" "$primary_level" "$refs_json" \
    "$(jq -cn --arg event "$event" --arg subject "$subject" --argjson related "$(printf '%s\n' "${related_ids[@]+"${related_ids[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
      '{event:$event,subjectId:$subject,relatedIds:$related}')"
  append_node "$nodes_ndjson" "$evidence_id" Evidence "Filed capture evidence: $event/$subject" \
    "$([ "$source_count" -gt 0 ] && printf AVAILABLE || printf UNKNOWN)" \
    "$event:$subject" "$primary_authority" "$primary_level" "$refs_json" \
    "$(jq -cn --argjson readable "$source_count" --argjson missing "$missing_count" \
      '{readableSourceCount:$readable,missingSourceCount:$missing}')"

  for path in "${sources[@]+"${sources[@]}"}"; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    i=$((i + 1))
    digest=$(sha256_file "$path")
    artifact_id="artifact:$key_short:$i"
    jq -cn --arg kind "$(source_kind "$event" "$path")" --arg locator "$path" --arg sha256 "$digest" \
      '[{kind:$kind,locator:$locator,sha256:$sha256}]' > "$tmp_root/artifact-refs.json"
    append_node "$nodes_ndjson" "$artifact_id" Artifact "Filed artifact: $(basename "$path")" \
      AVAILABLE "$event:$subject" FILED_EVIDENCE CONFIRMED "$tmp_root/artifact-refs.json" \
      "$(jq -cn --arg path "$path" --arg sha256 "$digest" '{path:$path,sha256:$sha256}')"
    edge_i=$((edge_i + 1))
    append_edge "$edges_ndjson" "edge:$key_short:$edge_i" "$artifact_id" belongs_to \
      "$snapshot_node_id" "$event:$subject" FILED_EVIDENCE CONFIRMED "$tmp_root/artifact-refs.json"
    edge_i=$((edge_i + 1))
    append_edge "$edges_ndjson" "edge:$key_short:$edge_i" "$artifact_id" valid_in \
      "$snapshot_node_id" "$event:$subject" FILED_EVIDENCE CONFIRMED "$tmp_root/artifact-refs.json"
  done

  claim_id="claim:$event:$key_short"
  append_node "$nodes_ndjson" "$claim_id" Claim "$primary_label" \
    "$([ "$primary_level" = CONFIRMED ] && printf ACTIVE || printf UNKNOWN)" \
    "$event:$subject" "$primary_authority" "$primary_level" "$refs_json" \
    "$(jq -cn --arg event "$event" '{predicate:"event-occurred",event:$event}')"
  edge_i=$((edge_i + 1))
  append_edge "$edges_ndjson" "edge:$key_short:$edge_i" "$evidence_id" supports "$claim_id" \
    "$event:$subject" "$primary_authority" "$primary_level" "$refs_json"

  i=0
  for inference in "${inferences[@]+"${inferences[@]}"}"; do
    i=$((i + 1))
    claim_id="claim:inferred:$key_short:$i"
    append_node "$nodes_ndjson" "$claim_id" Claim "$inference" PROPOSED "$event:$subject" \
      ADVISORY INFERRED "$refs_json" \
      "$(jq -cn '{predicate:"inferred-observation",adoptionRequired:true}')"
    edge_i=$((edge_i + 1))
    append_edge "$edges_ndjson" "edge:$key_short:$edge_i" "$evidence_id" supports "$claim_id" \
      "$event:$subject" ADVISORY INFERRED "$refs_json"
    jq -cn --arg reason "inferred claim $i requires captain adoption or filed evidence" '$reason' \
      >> "$reasons_ndjson"
  done

  for artifact_id in "$primary_id" "$evidence_id" "claim:$event:$key_short"; do
    edge_i=$((edge_i + 1))
    append_edge "$edges_ndjson" "edge:$key_short:$edge_i" "$artifact_id" valid_in \
      "$snapshot_node_id" "$event:$subject" "$primary_authority" "$primary_level" "$refs_json"
  done

  jq -cn --arg reason "active Goal, Spec, and WorkflowMap are not explicitly captured by this event" '$reason' \
    >> "$reasons_ndjson"
  if [ "$baseline_id" = UNKNOWN ]; then
    jq -cn --arg reason "active baselineId is unknown" '$reason' >> "$reasons_ndjson"
  fi
  jq -s 'unique' "$reasons_ndjson" > "$reasons_json"

  jq -s '.' "$nodes_ndjson" > "$nodes_json"
  if [ "$parent" != null ]; then
    jq -cn --arg locator "$previous_file" \
      '[{kind:"snapshot",locator:$locator,sha256:null}]' > "$tmp_root/parent-refs.json"
    edge_i=$((edge_i + 1))
    append_edge "$edges_ndjson" "edge:$key_short:$edge_i" "$snapshot_node_id" derived_from \
      "snapshot:$parent" "$event:$subject" FILED_EVIDENCE CONFIRMED "$tmp_root/parent-refs.json"
    jq -cn --arg id "snapshot:$parent" --arg parent "$parent" --slurpfile refs "$tmp_root/parent-refs.json" \
      '{id:$id,type:"Snapshot",revision:1,label:("Prior snapshot: " + $parent),status:"HISTORICAL",
        scope:"snapshot-lineage",authority:"FILED_EVIDENCE",
        epistemic:{level:"CONFIRMED",sourceRefs:$refs[0]},properties:{snapshotId:$parent}}' \
      >> "$nodes_ndjson"
    jq -s '.' "$nodes_ndjson" > "$nodes_json"
  fi
  jq -s '.' "$edges_ndjson" > "$edges_json"

  node_hash=$(json_array_hash "$nodes_json" '[.[] | select(.type != "Snapshot")]')
  edge_hash=$(json_array_hash "$edges_json" '.')
  decision_hash=$(json_array_hash "$nodes_json" '[.[] | select(.type == "Decision")]')
  spec_hash=$(json_array_hash "$nodes_json" '[.[] | select(.type == "Spec")]')
  artifact_hash=$(json_array_hash "$nodes_json" '[.[] | select(.type == "Artifact")]')

  jq -cn \
    --arg id "$snapshot_node_id" --arg label "SpecGraph snapshot $snapshot_id" \
    --arg baseline "$baseline_id" --argjson parent "$parent_json" \
    --arg effective "$effective_at" --arg captured "$captured_at" \
    --arg nodeHash "$node_hash" --arg edgeHash "$edge_hash" --arg decisionHash "$decision_hash" \
    --arg specHash "$spec_hash" --arg artifactHash "$artifact_hash" \
    --arg completeness "$authority_completeness" --arg status "$status" --arg snapshotId "$snapshot_id" \
    '{id:$id,type:"Snapshot",revision:1,label:$label,status:$status,scope:"snapshot",
      authority:"FILED_EVIDENCE",
      epistemic:{level:"CONFIRMED",sourceRefs:[{kind:"capture-receipt",locator:("snapshot:" + $snapshotId),sha256:null}]},
      properties:{baselineId:$baseline,parent:$parent,effectiveAt:$effective,capturedAt:$captured,
        setHashes:{nodeSetSha256:$nodeHash,edgeSetSha256:$edgeHash,decisionSetSha256:$decisionHash,
          specSetSha256:$specHash,artifactSetSha256:$artifactHash},
        authorityCompleteness:$completeness,status:$status}}' >> "$nodes_ndjson"
  jq -s '.' "$nodes_ndjson" > "$nodes_json"

  filename="$(printf '%012d' "$sequence")-$compact-$event-$subject-$key_short.json"
  final_tmp="$OUT_DIR/.snapshot.$$.$key_short.tmp"
  jq -n \
    --arg schema "$SCHEMA_VERSION" --argjson sequence "$sequence" --arg snapshotId "$snapshot_id" \
    --arg baseline "$baseline_id" --argjson parent "$parent_json" \
    --arg effective "$effective_at" --arg captured "$captured_at" \
    --arg nodeHash "$node_hash" --arg edgeHash "$edge_hash" --arg decisionHash "$decision_hash" \
    --arg specHash "$spec_hash" --arg artifactHash "$artifact_hash" \
    --arg completeness "$authority_completeness" --arg status "$status" \
    --arg event "$event" --arg subject "$subject" --arg key "$key" \
    --arg actorKind "$actor_kind" --arg actorHarness "$actor_harness" --arg actorModel "$actor_model" \
    --arg actorEffort "$actor_effort" --arg actorRole "$actor_role" --arg actorAuthority "$actor_authority" \
    --arg actorIndependence "$actor_independence" \
    --slurpfile refs "$refs_json" --slurpfile nodes "$nodes_json" --slurpfile edges "$edges_json" \
    --slurpfile reasons "$reasons_json" \
    '{schemaVersion:$schema,sequence:$sequence,snapshotId:$snapshotId,baselineId:$baseline,parent:$parent,
      effectiveAt:$effective,capturedAt:$captured,
      setHashes:{nodeSetSha256:$nodeHash,edgeSetSha256:$edgeHash,decisionSetSha256:$decisionHash,
        specSetSha256:$specHash,artifactSetSha256:$artifactHash},
      authorityCompleteness:$completeness,status:$status,incompleteReasons:$reasons[0],
      actor:{kind:$actorKind,harness:(if $actorHarness == "" then null else $actorHarness end),
        model:(if $actorModel == "" then null else $actorModel end),
        effort:(if $actorEffort == "" then null else $actorEffort end),role:$actorRole,
        authority:$actorAuthority,independence:$actorIndependence},
      trigger:{type:$event,subjectId:$subject,idempotencyKey:$key,sourceRefs:$refs[0]},
      nodes:$nodes[0],edges:$edges[0]}' > "$final_tmp"
  chmod 0600 "$final_tmp"
  command_validate "$final_tmp" >/dev/null || fail "generated snapshot failed validation"
  mv -f "$final_tmp" "$OUT_DIR/$filename"
  printf '%s\n' "$OUT_DIR/$filename"
  capture_cleanup
  trap - EXIT HUP INT TERM
}

case "${1:-}" in
  capture) shift; command_capture "$@" ;;
  validate)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    command_validate "$2"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
