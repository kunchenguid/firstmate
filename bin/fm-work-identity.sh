#!/usr/bin/env bash
# fm-work-identity.sh - exact, versioned project/plan/work-unit intake contract.
#
# This script is the single owner of the `fm-work-identity.v1` data contract,
# its validation rules, private storage, generated-instruction binding, metadata
# binding, and read-only projection shape. Other scripts consume this interface
# and must not parse, infer, or restate the contract.
#
# Public intake interface:
#   fm-work-identity.sh template <task-id>
#   fm-work-identity.sh record <task-id> --file <manifest.json>
#   fm-work-identity.sh verify <task-id>
#
# Internal consumers:
#   fm-work-identity.sh brief-block <task-id>
#   fm-work-identity.sh brief-publish <task-id> --file <draft.md>
#   fm-work-identity.sh project <task-id> [--brief <brief.md>] [--meta <task.meta>]
#   fm-work-identity.sh dispatch-binding <task-id> --brief <brief.md> [--meta <task.meta>]
#   fm-work-identity.sh dispatch-prepare <task-id> --brief <draft.md> --instructions-path <brief.md> --transaction <id> [--meta <task.meta> --prior-brief <brief.md>]
#   fm-work-identity.sh dispatch-commit-preflight <task-id> --brief <brief.md> --meta <task.meta> --transaction <id>
#   fm-work-identity.sh dispatch-publish <task-id> --brief <brief.md> --meta <metadata-candidate> --transaction <id>
#   fm-work-identity.sh dispatch-commit <task-id> --brief <brief.md> --meta <task.meta> --transaction <id>
#   fm-work-identity.sh dispatch-abort <task-id> --transaction <id>
#   fm-work-identity.sh dispatch-retire-preflight <task-id>
#   fm-work-identity.sh dispatch-retire-run <task-id> -- <command> [args...]
#   fm-work-identity.sh dispatch-retire <task-id>
#   fm-work-identity.sh metadata-publish-unlinked <task-id> --file <meta>
#   fm-work-identity.sh reserve-unlinked <task-id> --reason persistent-secondmate
#   fm-work-identity.sh unlinked-prepare <task-id> --reason persistent-secondmate --transaction <id>
#   fm-work-identity.sh unlinked-commit <task-id> --transaction <id>
#   fm-work-identity.sh unlinked-abort <task-id> --transaction <id>
#   fm-work-identity.sh home-id
#   fm-work-identity.sh handoff-prepare <task-id> --to-home <absolute-home> --to-home-id <home-id> [--backlog-sha256 <digest>] [--result]
#   fm-work-identity.sh handoff-stage <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-backlog-prepare <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-backlog-complete <task-id> --file <transfer.json|-> --backlog-sha256 <digest>
#   fm-work-identity.sh handoff-backlog-state <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-commit <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-abort <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-target-state <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-complete <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-cancel <task-id> --file <transfer.json|->
#   fm-work-identity.sh validate-index --file <index.json|->
#   fm-work-identity.sh validate-projections --home <absolute-home> --home-id <home-id> --file <records.json|->
#   fm-work-identity.sh publication-run -- <command> [args...]
#   fm-work-identity.sh limits
#   fm-work-identity.sh record-max-bytes
#
# The canonical private sidecar is data/<task-id>/work-identity.json.
# `record` accepts a pretty or compact JSON manifest, validates it, canonicalizes
# it to one sorted compact JSON object plus one newline, and publishes it
# atomically. Repeating the same record is idempotent. Once one canonical
# record wins no-clobber publication, only the byte-identical record is accepted;
# a changed relation requires a new task identity rather than in-place mutation.
#
# Complete schema `fm-work-identity.v1`:
# {
#   "schema": "fm-work-identity.v1",
#   "binding": {"home": "<physical absolute FM_HOME>", "home_id": "<stable-home-id>", "task_id": "<task-id>"},
#   "initiative": {"namespace": "...", "kind": "...", "id": "...", "label": "..."},
#   "plan_id":    {"namespace": "...", "kind": "plan", "id": "...", "label": "..."},
#   "stage":      {"namespace": "...", "kind": "stage", "id": "...", "label": "..."},
#   "work_units": [{"namespace": "...", "kind": "work-unit", "id": "...", "label": "..."}],
#   "sources":    [{"namespace": "...", "kind": "...", "id": "...", "label": "..."}]
# }
#
# Every identity is the exact tuple (namespace, kind, id). `label` is mandatory
# display text paired with that tuple and never establishes identity.
# Closed namespace/kind roles:
#   initiative: work-aligner project|initiative; dtm project;
#               firstmate project|initiative
#   plan_id:    work-aligner plan; firstmate plan
#   stage:      work-aligner stage; firstmate stage
#   work_units: work-aligner work-unit; firstmate work-unit
#   sources:    work-aligner project|initiative|plan|stage|work-unit;
#               dtm project|issue; data-team-ticket ticket;
#               firstmate project|initiative|plan|stage|work-unit
# This keeps Work Aligner plan/work-unit ids, DTM project/issue ids, Data Team
# Ticket ids, and local Firstmate plan/work-unit ids in distinct namespaces.
#
# A task has exactly one initiative/plan/stage context and one or more exact
# work units and source identities. It is projected once as a worker with arrays
# of those units, so several units never multiply the worker count.
#
# Syntax and safety:
#   - new intake task ids use Firstmate's canonical creation grammar and are at most 64 bytes;
#     lifecycle reads retain Firstmate's path-safe legacy task grammar;
#   - ids are 1..240 ASCII bytes, begin alphanumeric, and use only
#     A-Z a-z 0-9 . _ : @ / # ~ -; path-like '.', '..', empty, leading, or
#     trailing slash segments are refused;
#   - labels are 1..160 characters, have no leading/trailing whitespace,
#     Unicode control or format characters, Unicode line separators, or Markdown
#     table/HTML/backslash metacharacters, and are never paths;
#   - work_units and sources each contain 1..20 identities;
#   - no exact identity tuple may occur twice anywhere in one record;
#   - the manifest and sidecar are bounded regular, non-symlink, single-link
#     files; task directories are direct non-symlink children of the configured
#     data directory;
#   - binding.home, binding.home_id, and binding.task_id must exactly match the
#     physical active home, its stable `main` or `secondmate:<id>` identity, and
#     command task id, so same-path remote copies, other cross-home copies, and
#     task-mismatched records are refused;
#   - backlog handoff uses durable source and target prepare records. New intake
#     and projection stop while ownership is prepared; destination publication,
#     source completion, and cancellation are exact-transfer idempotent steps;
#   - linked live tasks require matching schema/status/digest fields in metadata
#     and byte-matching digest and payload markers in generated instructions;
#   - absent records remain compatible and project explicitly as unlinked.
#
# Reads and records are local identity bookkeeping only. They never change task
# lifecycle state, assignments, a DTM item, GitHub, a Data Team Ticket, or a Work
# Aligner plan. No title, repository, branch, endpoint, worker name, timestamp,
# label, or status prose is ever consulted as a fallback relation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_INPUT="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FS_OWNER="$SCRIPT_DIR/fm-work-identity-fs.py"
SCHEMA=fm-work-identity.v1
HANDOFF_SCHEMA=fm-work-identity-handoff.v2
HANDOFF_STATE_SCHEMA=fm-work-identity-handoff-state.v2
DISPATCH_STATE_SCHEMA=fm-work-identity-dispatch-state.v2
UNLINKED_GUARD_SCHEMA=fm-work-identity-unlinked-guard.v1
UNLINKED_RESERVATION_SCHEMA=fm-work-identity-unlinked-reservation.v1
MAX_BYTES=65536
HANDOFF_MAX_BYTES=$((MAX_BYTES + 8192))
MAX_ARRAY=20
MAX_PROJECTION_BYTES=$((MAX_BYTES + 2048))
MAX_PROJECTION_BATCH_BYTES=1048576
DIE_STATUS=1
case "${1:-}" in publication-run) DIE_STATUS=42 ;; esac
FM_HOME_ID=
LOCATED_TASK=
TASK_DIR=
TASK_DIR_ID=
ACTIVE_IDENTITY_LOCK=
ACTIVE_IDENTITY_LOCK_PARENT=
ACTIVE_IDENTITY_LOCK_PARENT_ID=
ACTIVE_IDENTITY_LOCK_TOKEN=
ACTIVE_IDENTITY_LOCK_HELD=0
ACTIVE_IDENTITY_LOCK_EXTERNAL=0
ACTIVE_PUBLICATION_LOCK=
ACTIVE_PUBLICATION_LOCK_PARENT=
ACTIVE_PUBLICATION_LOCK_PARENT_ID=
ACTIVE_PUBLICATION_LOCK_TOKEN=
ACTIVE_PUBLICATION_LOCK_HELD=0
ACTIVE_PUBLICATION_LOCK_EXTERNAL=0
RECORD_HANDOFF_TRANSITION=0
RECORD_HANDOFF_TRANSFER=
CONTRACT_INPUT_TMP=
VALIDATION_TMP=
MANIFEST_CAPTURE_TMP=
MANIFEST_CAPTURE_SOURCE=
SIDECAR_SNAPSHOT_TMP=
META_CAPTURE_TMP=
META_CAPTURE_SOURCE=
META_CAPTURE_PARENT=
META_CAPTURE_PARENT_ID=
META_CAPTURE_BASE=
META_CAPTURE_ENTRY_STATE=
META_CAPTURE_ENTRY_DIGEST=
BRIEF_INPUT_TMP=
BRIEF_HASH=
BRIEF_VALIDATED_CAPTURE=
RETAIN_BRIEF_CAPTURE=0
PROJECTION_TMP=
DISPATCH_PRIOR_TMP=
DISPATCH_PRIOR_CLEANUP=0
PUBLICATION_STAGING=
TMP=

work_identity_cleanup() {
  local status=$?
  [ -z "${TMP:-}" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "${CONTRACT_INPUT_TMP:-}" ] || rm -f -- "$CONTRACT_INPUT_TMP" 2>/dev/null || true
  [ -z "${VALIDATION_TMP:-}" ] || rm -f -- "$VALIDATION_TMP" 2>/dev/null || true
  [ -z "${MANIFEST_CAPTURE_TMP:-}" ] || rm -f -- "$MANIFEST_CAPTURE_TMP" 2>/dev/null || true
  [ -z "${SIDECAR_SNAPSHOT_TMP:-}" ] || rm -f -- "$SIDECAR_SNAPSHOT_TMP" 2>/dev/null || true
  [ -z "${META_CAPTURE_TMP:-}" ] || rm -f -- "$META_CAPTURE_TMP" 2>/dev/null || true
  [ -z "${BRIEF_INPUT_TMP:-}" ] || rm -f -- "$BRIEF_INPUT_TMP" 2>/dev/null || true
  [ -z "${BRIEF_VALIDATED_CAPTURE:-}" ] || rm -f -- "$BRIEF_VALIDATED_CAPTURE" 2>/dev/null || true
  [ -z "${PROJECTION_TMP:-}" ] || rm -f -- "$PROJECTION_TMP" 2>/dev/null || true
  [ -z "${DISPATCH_PRIOR_TMP:-}" ] || rm -f -- "$DISPATCH_PRIOR_TMP" 2>/dev/null || true
  [ -z "${PUBLICATION_STAGING:-}" ] || rm -f -- "$PUBLICATION_STAGING" 2>/dev/null || true
  if [ "${DISPATCH_PRIOR_CLEANUP:-0}" -eq 1 ]; then
    DISPATCH_PRIOR_CLEANUP=0
    rm -f -- "${DISPATCH_PRIOR:-}" 2>/dev/null || true
  fi
  if [ "${ACTIVE_IDENTITY_LOCK_HELD:-0}" -eq 1 ]; then
    ACTIVE_IDENTITY_LOCK_HELD=0
    if [ "${ACTIVE_IDENTITY_LOCK_EXTERNAL:-0}" -ne 1 ]; then
      python3 "$FS_OWNER" lock-release "$ACTIVE_IDENTITY_LOCK_PARENT" \
        "$ACTIVE_IDENTITY_LOCK_PARENT_ID" "$ACTIVE_IDENTITY_LOCK" \
        "${BASHPID:-$$}" "$ACTIVE_IDENTITY_LOCK_TOKEN" >/dev/null 2>&1 || true
    fi
  fi
  if [ "${ACTIVE_PUBLICATION_LOCK_HELD:-0}" -eq 1 ]; then
    ACTIVE_PUBLICATION_LOCK_HELD=0
    if [ "${ACTIVE_PUBLICATION_LOCK_EXTERNAL:-0}" -ne 1 ]; then
      python3 "$FS_OWNER" lock-release "$ACTIVE_PUBLICATION_LOCK_PARENT" \
        "$ACTIVE_PUBLICATION_LOCK_PARENT_ID" "$ACTIVE_PUBLICATION_LOCK" \
        "${BASHPID:-$$}" "$ACTIVE_PUBLICATION_LOCK_TOKEN" >/dev/null 2>&1 || true
    fi
  fi
  return "$status"
}
trap work_identity_cleanup EXIT

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "$DIE_STATUS"
}

resolve_existing_dir() {  # <name> <path>
  local name=$1 path=$2 resolved
  [ -d "$path" ] || die "$name directory is unavailable: $path"
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) \
    || die "$name directory cannot be resolved: $path"
  printf '%s\n' "$resolved"
}

directory_inode_identity() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

resolve_owned_dir() {  # <name> <path> [expected-real] [expected-inode]
  local name=$1 path=$2 expected_real=${3:-} expected_inode=${4:-}
  local before resolved resolved_inode after
  [ ! -L "$path" ] || die "$name directory is symlinked: $path"
  [ -d "$path" ] || die "$name directory is unavailable: $path"
  before=$(directory_inode_identity "$path") \
    || die "$name directory cannot be inspected: $path"
  resolved=$(resolve_existing_dir "$name" "$path")
  [ ! -L "$path" ] && [ -d "$path" ] \
    || die "$name directory changed while it was being resolved: $path"
  after=$(directory_inode_identity "$path") \
    || die "$name directory cannot be reinspected: $path"
  resolved_inode=$(directory_inode_identity "$resolved") \
    || die "$name resolved directory cannot be inspected: $resolved"
  [ "$before" = "$after" ] && [ "$before" = "$resolved_inode" ] \
    || die "$name directory changed while it was being resolved: $path"
  [ -z "$expected_real" ] || [ "$resolved" = "$expected_real" ] \
    || die "$name directory changed from its validated location: $path"
  [ -z "$expected_inode" ] || [ "$resolved_inode" = "$expected_inode" ] \
    || die "$name directory was replaced after validation: $path"
  printf '%s\t%s\n' "$resolved" "$resolved_inode"
}

IFS=$'\t' read -r FM_HOME_REAL HOME_DIR_ID < <(resolve_owned_dir FM_HOME "$FM_HOME_INPUT")
DATA_INPUT=${FM_DATA_OVERRIDE:-$FM_HOME_REAL/data}
STATE_INPUT=${FM_STATE_OVERRIDE:-$FM_HOME_REAL/state}
DATA_PARENT_INPUT=$(dirname -- "$DATA_INPUT")
STATE_PARENT_INPUT=$(dirname -- "$STATE_INPUT")
DATA_BASE=$(basename -- "$DATA_INPUT")
STATE_BASE=$(basename -- "$STATE_INPUT")
[ "$DATA_BASE" != . ] && [ "$DATA_BASE" != .. ] \
  || die "data directory path is unsafe: $DATA_INPUT"
[ "$STATE_BASE" != . ] && [ "$STATE_BASE" != .. ] \
  || die "state directory path is unsafe: $STATE_INPUT"
IFS=$'\t' read -r DATA_PARENT_REAL DATA_PARENT_ID \
  < <(resolve_owned_dir data-parent "$DATA_PARENT_INPUT")
IFS=$'\t' read -r STATE_PARENT_REAL STATE_PARENT_ID \
  < <(resolve_owned_dir state-parent "$STATE_PARENT_INPUT")
if [ "$DATA_PARENT_REAL" = "$FM_HOME_REAL" ]; then
  [ "$DATA_PARENT_ID" = "$HOME_DIR_ID" ] \
    || die "FM_HOME was replaced before data storage was anchored"
fi
if [ "$STATE_PARENT_REAL" = "$FM_HOME_REAL" ]; then
  [ "$STATE_PARENT_ID" = "$HOME_DIR_ID" ] \
    || die "FM_HOME was replaced before state storage was anchored"
fi
DATA_INPUT="$DATA_PARENT_REAL/$DATA_BASE"
STATE_INPUT="$STATE_PARENT_REAL/$STATE_BASE"
DATA_DIR_ID=
STATE_DIR_ID=
if [ -e "$DATA_INPUT" ] || [ -L "$DATA_INPUT" ]; then
  IFS=$'\t' read -r DATA_REAL DATA_DIR_ID < <(resolve_owned_dir data "$DATA_INPUT")
else
  DATA_REAL=$DATA_INPUT
fi
if [ -e "$STATE_INPUT" ] || [ -L "$STATE_INPUT" ]; then
  IFS=$'\t' read -r STATE_REAL STATE_DIR_ID < <(resolve_owned_dir state "$STATE_INPUT")
else
  STATE_REAL=$STATE_INPUT
fi

file_link_count() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

file_size() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%z' "$1" 2>/dev/null
  else
    stat -c '%s' "$1" 2>/dev/null
  fi
}

file_identity() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i:%l:%z' "$1" 2>/dev/null
  else
    stat -c '%d:%i:%h:%s' "$1" 2>/dev/null
  fi
}

file_inode_identity() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

safe_regular_file() {  # <path> <label> [max-bytes]
  local path=$1 label=$2 max=${3:-$MAX_BYTES} links bytes
  [ ! -L "$path" ] || die "$label is symlinked: $path"
  [ -f "$path" ] || die "$label is not a regular file: $path"
  links=$(file_link_count "$path") || die "cannot inspect $label link count: $path"
  [ "$links" = 1 ] || die "$label is hardlinked: $path"
  bytes=$(file_size "$path") || die "cannot inspect $label size: $path"
  case "$bytes" in ''|*[!0-9]*) die "$label has an invalid size: $path" ;; esac
  [ "$bytes" -le "$max" ] || die "$label exceeds $max bytes: $path"
}

recover_no_clobber_target() {  # <target> <label>
  local target=$1 label=$2 staging target_links staging_links target_inode staging_inode parent expected base
  staging="${target}.publishing"
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  python3 "$FS_OWNER" describe-raw "$parent" "$expected" "$base" >/dev/null \
    || die "cannot recover $label publication: $target"
  [ -e "$staging" ] || [ -L "$staging" ] || return 0
  [ ! -L "$staging" ] || die "$label publication staging path is symlinked: $staging"
  [ -f "$staging" ] || die "$label publication staging path is not a regular file: $staging"
  staging_links=$(file_link_count "$staging") \
    || die "cannot inspect $label publication staging link count: $staging"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    [ "$staging_links" = 1 ] \
      || die "$label publication staging path is unexpectedly hardlinked: $staging"
    owned_remove_staging "$staging" "$label publication staging path"
    return 0
  fi
  [ ! -L "$target" ] || die "$label is symlinked: $target"
  [ -f "$target" ] || die "$label is not a regular file: $target"
  target_links=$(file_link_count "$target") || die "cannot inspect $label link count: $target"
  [ "$target_links" = 2 ] && [ "$staging_links" = 2 ] \
    || die "$label publication has an invalid recovery link count: $target"
  target_inode=$(file_inode_identity "$target") || die "cannot inspect $label inode: $target"
  staging_inode=$(file_inode_identity "$staging") \
    || die "cannot inspect $label publication staging inode: $staging"
  [ "$target_inode" = "$staging_inode" ] \
    || die "$label publication staging path does not own the authoritative record: $staging"
  owned_remove_staging "$staging" "$label publication staging path"
  target_links=$(file_link_count "$target") || die "cannot reinspect $label link count: $target"
  [ "$target_links" = 1 ] || die "$label publication recovery did not restore one link: $target"
}

recover_no_clobber_publications() {
  recover_no_clobber_target "$SIDECAR" "work identity record"
  recover_no_clobber_target "$BRIEF_DEFAULT" "generated instructions"
  recover_no_clobber_target "$UNLINKED_GUARD" "work identity unlinked guard"
  recover_no_clobber_target "$UNLINKED_RESERVATION" "work identity unlinked reservation"
}

owned_parent_details() {  # <target>
  local target=$1 parent
  parent=$(dirname -- "$target") || return 1
  if [ "$parent" = "$TASK_DIR" ] && [ -n "$TASK_DIR_ID" ]; then
    printf '%s\t%s\n' "$TASK_DIR" "$TASK_DIR_ID"
  elif [ "$parent" = "$STATE_REAL" ] && [ -n "$STATE_DIR_ID" ]; then
    printf '%s\t%s\n' "$STATE_REAL" "$STATE_DIR_ID"
  elif [ "$parent" = "$DATA_REAL" ] && [ -n "$DATA_DIR_ID" ]; then
    printf '%s\t%s\n' "$DATA_REAL" "$DATA_DIR_ID"
  else
    return 1
  fi
}

owned_atomic_replace() {  # <source> <target> <label>
  local source=$1 target=$2 label=$3 parent expected base details destination_state destination_digest
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  details=$(python3 "$FS_OWNER" describe-replace "$parent" "$expected" "$base") \
    || die "$label destination is unsafe: $target"
  destination_state=${details%%$'\t'*}
  destination_digest=${details#*$'\t'}
  [ "$destination_state" != "$details" ] || die "$label destination identity is malformed: $target"
  owned_atomic_replace_expected "$source" "$target" "$label" \
    "$destination_state" "$destination_digest"
}

owned_atomic_replace_expected() {  # <source> <target> <label> <validated-state> <validated-digest>
  local source=$1 target=$2 label=$3 destination_state=$4 destination_digest=$5 parent expected base
  local source_details source_state source_digest
  [ -n "$destination_state" ] && [ -n "$destination_digest" ] \
    || die "$label has no validated destination identity"
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  source_details=$(python3 "$FS_OWNER" describe-source "$source" "$MAX_BYTES") \
    || die "$label publication source is unsafe: $source"
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  [ "$source_state" != "$source_details" ] \
    || die "$label publication source identity is malformed: $source"
  python3 "$FS_OWNER" replace "$parent" "$expected" "$base" "$source" \
    "$destination_state" "$destination_digest" "$source_state" "$source_digest" \
    || die "cannot publish $label: $target"
  rm -f -- "$source" || die "cannot retire $label publication source"
  [ "${TMP:-}" != "$source" ] || TMP=
}

recover_owned_replacement() {  # <target> <label>
  local target=$1 label=$2 parent expected base
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  python3 "$FS_OWNER" describe "$parent" "$expected" "$base" >/dev/null \
    || die "cannot recover $label publication: $target"
}

owned_removal_expectation() {  # <target> <label>
  local target=$1 label=$2 parent expected base
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  python3 "$FS_OWNER" describe-digest "$parent" "$expected" "$base" \
    || die "$label destination is unsafe: $target"
}

owned_remove() {  # <target> <label> <validated-state> <validated-digest>
  local target=$1 label=$2 destination_state=$3 destination_digest=$4 parent expected base
  [ -n "$destination_state" ] && [ -n "$destination_digest" ] \
    || die "$label has no validated removal identity"
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  python3 "$FS_OWNER" remove "$parent" "$expected" "$base" \
    "$destination_state" "$destination_digest" \
    || die "cannot remove $label: $target"
}

owned_remove_staging() {  # <target> <label>
  local target=$1 label=$2 parent expected base destination_state
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  destination_state=$(python3 "$FS_OWNER" describe-raw "$parent" "$expected" "$base") \
    || die "$label destination is unsafe: $target"
  python3 "$FS_OWNER" remove-staging "$parent" "$expected" "$base" "$destination_state" \
    || die "cannot remove $label: $target"
}

publish_no_clobber() {  # <source> <target> <label>; 2 means target already exists
  local source=$1 target=$2 label=$3 parent expected base staging rc
  local source_details source_state source_digest
  IFS=$'\t' read -r parent expected < <(owned_parent_details "$target") \
    || die "$label target parent is not owned: $target"
  base=$(basename -- "$target") || die "cannot resolve $label target name"
  staging="${base}.publishing"
  source_details=$(python3 "$FS_OWNER" describe-source "$source" "$MAX_BYTES") \
    || die "$label publication source is unsafe: $source"
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  [ "$source_state" != "$source_details" ] \
    || die "$label publication source identity is malformed: $source"
  rc=0
  if python3 "$FS_OWNER" no-clobber "$parent" "$expected" "$base" "$source" "$staging" \
      "$source_state" "$source_digest"; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0)
      rm -f -- "$source" || die "cannot retire $label publication source"
      [ "${TMP:-}" != "$source" ] || TMP=
      return 0
      ;;
    2) return 2 ;;
    *) die "cannot publish $label: $target" ;;
  esac
}

home_id_literal_valid() {  # <main|secondmate:id>
  local value=$1 id
  [ "$value" = main ] && return 0
  case "$value" in secondmate:*) id=${value#secondmate:} ;; *) return 1 ;; esac
  [ "${#id}" -le 128 ] || return 1
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

ensure_home_identity() {
  local marker id
  [ -z "$FM_HOME_ID" ] || return 0
  marker="$FM_HOME_REAL/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    FM_HOME_ID=main
    return 0
  fi
  safe_regular_file "$marker" "secondmate home identity marker" 256
  id=$(cat "$marker") || die "cannot read secondmate home identity marker: $marker"
  printf '%s\n' "$id" | cmp -s "$marker" - \
    || die "secondmate home identity marker is not one exact line: $marker"
  home_id_literal_valid "secondmate:$id" \
    || die "secondmate home identity marker is malformed: $marker"
  FM_HOME_ID="secondmate:$id"
}

create_owned_directory() {  # <name> <path>
  local name=$1 path=$2 parent base expected created
  parent=$(dirname -- "$path") || die "cannot resolve $name directory parent: $path"
  base=$(basename -- "$path") || die "cannot resolve $name directory name: $path"
  [ "$base" != . ] && [ "$base" != .. ] || die "$name directory path is unsafe: $path"
  if [ "$parent" = "$DATA_PARENT_REAL" ]; then
    expected=$DATA_PARENT_ID
  elif [ "$parent" = "$STATE_PARENT_REAL" ]; then
    expected=$STATE_PARENT_ID
  else
    die "$name directory parent is not owned: $parent"
  fi
  created=$(python3 "$FS_OWNER" mkdir "$parent" "$expected" "$base") \
    || die "cannot create $name directory: $path"
  case "$created" in *:* ) ;; *) die "cannot anchor created $name directory: $path" ;; esac
  printf '%s\n' "$created"
}

ensure_data_dir() {
  local resolved inode
  if [ ! -e "$DATA_INPUT" ] && [ ! -L "$DATA_INPUT" ]; then
    [ -z "$DATA_DIR_ID" ] \
      || die "data directory disappeared after validation: $DATA_INPUT"
    DATA_DIR_ID=$(create_owned_directory data "$DATA_INPUT")
  fi
  IFS=$'\t' read -r resolved inode \
    < <(resolve_owned_dir data "$DATA_INPUT" "${DATA_DIR_ID:+$DATA_REAL}" "$DATA_DIR_ID")
  DATA_REAL=$resolved
  DATA_DIR_ID=$inode
}

ensure_state_dir() {
  local resolved inode
  if [ ! -e "$STATE_INPUT" ] && [ ! -L "$STATE_INPUT" ]; then
    [ -z "$STATE_DIR_ID" ] \
      || die "state directory disappeared after validation: $STATE_INPUT"
    STATE_DIR_ID=$(create_owned_directory state "$STATE_INPUT")
  fi
  IFS=$'\t' read -r resolved inode \
    < <(resolve_owned_dir state "$STATE_INPUT" "${STATE_DIR_ID:+$STATE_REAL}" "$STATE_DIR_ID")
  STATE_REAL=$resolved
  STATE_DIR_ID=$inode
}

lock_parent_preflight() {  # <directory> <label>
  local directory=$1 label=$2 expected
  if [ "$directory" = "$DATA_REAL" ]; then
    expected=$DATA_DIR_ID
  elif [ "$directory" = "$STATE_REAL" ]; then
    expected=$STATE_DIR_ID
  else
    die "$label lock directory is not owned: $directory"
  fi
  python3 "$FS_OWNER" probe "$directory" "$expected" work-identity-lock-check \
    || die "$label lock directory is not writable: $directory"
}

locate_task_dir() {  # <task-id>, read-only
  local id=$1 dir real inode
  if [ "$LOCATED_TASK" != "$id" ]; then
    TASK_DIR_ID=
  fi
  LOCATED_TASK=$id
  if [ -e "$DATA_INPUT" ] || [ -L "$DATA_INPUT" ]; then
    local resolved inode
    IFS=$'\t' read -r resolved inode \
      < <(resolve_owned_dir data "$DATA_INPUT" "${DATA_DIR_ID:+$DATA_REAL}" "$DATA_DIR_ID")
    DATA_REAL=$resolved
    DATA_DIR_ID=$inode
  fi
  dir="$DATA_REAL/$id"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ ! -L "$dir" ] || die "task data directory is symlinked: $dir"
    [ -d "$dir" ] || die "task data path is not a directory: $dir"
    real=$(resolve_existing_dir task-data "$dir")
    [ "$real" = "$DATA_REAL/$id" ] || die "task data directory escapes the configured data directory: $dir"
    inode=$(directory_inode_identity "$real") \
      || die "task data directory cannot be inspected: $dir"
    [ -z "$TASK_DIR_ID" ] || [ "$inode" = "$TASK_DIR_ID" ] \
      || die "task data directory was replaced after validation: $dir"
    TASK_DIR=$real
    TASK_DIR_ID=$inode
  else
    [ -z "$TASK_DIR_ID" ] || die "task data directory disappeared after validation: $dir"
    TASK_DIR=$dir
  fi
  SIDECAR="$TASK_DIR/work-identity.json"
  BRIEF_DEFAULT="$TASK_DIR/brief.md"
  SOURCE_HANDOFF="$TASK_DIR/work-identity-handoff-source.json"
  TARGET_HANDOFF="$TASK_DIR/work-identity-handoff-target.json"
  DISPATCH_STATE="$TASK_DIR/work-identity-dispatch.json"
  DISPATCH_PRIOR="$TASK_DIR/work-identity-dispatch-prior.md"
  UNLINKED_GUARD="$TASK_DIR/work-identity-unlinked-guard.json"
  UNLINKED_RESERVATION="$TASK_DIR/work-identity-unlinked-reservation.json"
}

ensure_task_dir() {  # <task-id>
  local id=$1 created
  ensure_data_dir
  locate_task_dir "$id"
  if [ ! -d "$TASK_DIR" ]; then
    if created=$(python3 "$FS_OWNER" mkdir "$DATA_REAL" "$DATA_DIR_ID" "$id"); then
      TASK_DIR_ID=$created
    else
      [ -d "$TASK_DIR" ] && [ ! -L "$TASK_DIR" ] \
        || die "cannot create task data directory: $TASK_DIR"
    fi
    locate_task_dir "$id"
  fi
}

canonicalize_manifest() {  # <path> <task-id> [expected-home] [expected-home-id]
  local path=$1 task=$2 expected_home=${3:-$FM_HOME_REAL} expected_home_id=${4:-} out
  if [ -z "$expected_home_id" ]; then
    ensure_home_identity
    expected_home_id=$FM_HOME_ID
  fi
  home_id_literal_valid "$expected_home_id" || die "work identity home id is malformed: $expected_home_id"
  out=$(jq -e -S -c -s \
    --arg schema "$SCHEMA" \
    --arg home "$expected_home" \
    --arg home_id "$expected_home_id" \
    --arg task "$task" \
    --argjson max_array "$MAX_ARRAY" '
      def exact_keys($ks): (keys | sort) == ($ks | sort);
      def safe_id:
        type == "string" and (length >= 1 and length <= 240)
        and test("^[A-Za-z0-9][A-Za-z0-9._:@/#~-]*$")
        and (startswith("/") | not) and (endswith("/") | not)
        and (contains("//") | not)
        and (test("(^|/)\\.\\.?(/|$)") | not);
      def safe_label:
        type == "string" and (length >= 1 and length <= 160)
        and . == (gsub("^[[:space:]]+|[[:space:]]+$"; ""))
        and (test("[\\p{Cc}\\p{Cf}]") | not)
        and (([explode[] | select(
          . == 60 or . == 62 or . == 92 or . == 96 or . == 124
          or . == 8232 or . == 8233)] | length) == 0)
        and . != "." and . != "..";
      def identity:
        type == "object" and exact_keys(["namespace","kind","id","label"])
        and (.namespace | type == "string")
        and (.kind | type == "string")
        and (.id | safe_id)
        and (.label | safe_label);
      def key: [.namespace,.kind,.id] | join("\u001f");
      def allowed($pairs): . as $i | identity and ($pairs | index($i.namespace + ":" + $i.kind) != null);
      select(length == 1) | .[0] | . as $manifest | select(
      exact_keys(["schema","binding","initiative","plan_id","stage","work_units","sources"])
      and .schema == $schema
      and (.binding | type == "object" and exact_keys(["home","home_id","task_id"])
        and .home == $home and .home_id == $home_id and .task_id == $task)
      and (.initiative | allowed([
        "work-aligner:project","work-aligner:initiative","dtm:project",
        "firstmate:project","firstmate:initiative"]))
      and (.plan_id | allowed(["work-aligner:plan","firstmate:plan"]))
      and (.stage | allowed(["work-aligner:stage","firstmate:stage"]))
      and (.work_units | type == "array" and length >= 1 and length <= $max_array
        and all(.[]; allowed(["work-aligner:work-unit","firstmate:work-unit"])))
      and (.sources | type == "array" and length >= 1 and length <= $max_array
        and all(.[]; allowed([
          "work-aligner:project","work-aligner:initiative","work-aligner:plan",
          "work-aligner:stage","work-aligner:work-unit",
          "dtm:project","dtm:issue","data-team-ticket:ticket",
          "firstmate:project","firstmate:initiative","firstmate:plan",
          "firstmate:stage","firstmate:work-unit"])))
      and (([.initiative,.plan_id,.stage] + .work_units + .sources) as $all
        | ($all | map(key) | unique | length) == ($all | length))
      ) | $manifest
    ' "$path" 2>/dev/null) || die "manifest does not satisfy $SCHEMA"
  printf '%s\n' "$out"
}

capture_manifest() {  # <path>
  local path=$1
  MANIFEST_CAPTURE_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-manifest.XXXXXX") \
    || die "cannot capture work identity manifest"
  python3 "$FS_OWNER" snapshot-path "$path" "$MAX_BYTES" > "$MANIFEST_CAPTURE_TMP" \
    || die "cannot capture work identity manifest"
  safe_regular_file "$MANIFEST_CAPTURE_TMP" "captured work identity manifest"
  MANIFEST_CAPTURE_SOURCE=$path
}

verify_manifest_capture() {
  local current
  current=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-manifest-check.XXXXXX") \
    || die "cannot recapture work identity manifest"
  python3 "$FS_OWNER" snapshot-path "$MANIFEST_CAPTURE_SOURCE" "$MAX_BYTES" > "$current" \
    || { rm -f -- "$current"; die "work identity manifest changed before publication"; }
  cmp -s "$MANIFEST_CAPTURE_TMP" "$current" \
    || { rm -f -- "$current"; die "work identity manifest changed before publication"; }
  rm -f -- "$current"
}

validate_sidecar() {  # <path> <task-id> [expected-home] [expected-home-id]; sets WORK_CANONICAL/WORK_HASH
  local path=$1 task=$2 expected_home=${3:-$FM_HOME_REAL} expected_home_id=${4:-}
  local before after canonical parent expected base details state digest owned=0
  SIDECAR_SNAPSHOT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-record.XXXXXX") \
    || die "cannot capture work identity record"
  if IFS=$'\t' read -r parent expected < <(owned_parent_details "$path"); then
    base=$(basename -- "$path") || die "cannot resolve work identity record name"
    details=$(python3 "$FS_OWNER" describe-digest "$parent" "$expected" "$base") \
      || die "work identity record is unsafe: $path"
    state=${details%%$'\t'*}
    digest=${details#*$'\t'}
    [ "$state" != "$details" ] || die "cannot inspect work identity record: $path"
    python3 "$FS_OWNER" snapshot "$parent" "$expected" "$base" "$state" "$digest" \
      > "$SIDECAR_SNAPSHOT_TMP" || die "cannot capture work identity record: $path"
    owned=1
  else
    safe_regular_file "$path" "work identity record"
    before=$(file_identity "$path") || die "cannot inspect work identity record: $path"
    cp -- "$path" "$SIDECAR_SNAPSHOT_TMP" || die "cannot capture work identity record: $path"
    after=$(file_identity "$path") || die "cannot reinspect work identity record: $path"
    if [ "$before" != "$after" ] || ! cmp -s "$path" "$SIDECAR_SNAPSHOT_TMP"; then
      die "work identity record changed while it was captured: $path"
    fi
  fi
  safe_regular_file "$SIDECAR_SNAPSHOT_TMP" "captured work identity record"
  canonical=$(canonicalize_manifest "$SIDECAR_SNAPSHOT_TMP" "$task" "$expected_home" "$expected_home_id")
  if ! printf '%s\n' "$canonical" | cmp -s "$SIDECAR_SNAPSHOT_TMP" -; then
    die "work identity record is not canonical or has trailing data: $path"
  fi
  WORK_HASH=$(sha256_file "$SIDECAR_SNAPSHOT_TMP") || die "SHA-256 is unavailable for work identity record"
  case "$WORK_HASH" in ''|*[!A-Fa-f0-9]*) die "work identity SHA-256 is invalid" ;; esac
  [ "${#WORK_HASH}" -eq 64 ] || die "work identity SHA-256 has the wrong length"
  WORK_HASH=$(printf '%s' "$WORK_HASH" | tr 'A-F' 'a-f')
  if [ "$owned" -eq 1 ]; then
    details=$(python3 "$FS_OWNER" describe-digest "$parent" "$expected" "$base") \
      || die "cannot reinspect work identity record: $path"
    [ "$details" = "$state"$'\t'"$digest" ] \
      || die "work identity record changed while it was validated: $path"
  else
    after=$(file_identity "$path") || die "cannot reinspect work identity record: $path"
    if [ "$before" != "$after" ] || ! cmp -s "$path" "$SIDECAR_SNAPSHOT_TMP"; then
      die "work identity record changed while it was validated: $path"
    fi
  fi
  rm -f -- "$SIDECAR_SNAPSHOT_TMP"
  SIDECAR_SNAPSHOT_TMP=
  WORK_CANONICAL=$canonical
}

capture_metadata() {  # <meta>
  local meta=$1 details
  [ -z "$META_CAPTURE_SOURCE" ] || {
    [ "$META_CAPTURE_SOURCE" = "$meta" ] || die "cannot validate two task metadata files concurrently"
    return 0
  }
  META_CAPTURE_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-meta.XXXXXX") \
    || die "cannot capture task metadata: $meta"
  if IFS=$'\t' read -r META_CAPTURE_PARENT META_CAPTURE_PARENT_ID < <(owned_parent_details "$meta"); then
    META_CAPTURE_BASE=$(basename -- "$meta") || die "cannot resolve task metadata name: $meta"
    details=$(python3 "$FS_OWNER" describe-digest \
      "$META_CAPTURE_PARENT" "$META_CAPTURE_PARENT_ID" "$META_CAPTURE_BASE") \
      || die "task metadata is unsafe: $meta"
    META_CAPTURE_ENTRY_STATE=${details%%$'\t'*}
    META_CAPTURE_ENTRY_DIGEST=${details#*$'\t'}
    [ "$META_CAPTURE_ENTRY_STATE" != "$details" ] || die "cannot inspect task metadata: $meta"
    python3 "$FS_OWNER" snapshot "$META_CAPTURE_PARENT" "$META_CAPTURE_PARENT_ID" \
      "$META_CAPTURE_BASE" "$META_CAPTURE_ENTRY_STATE" "$META_CAPTURE_ENTRY_DIGEST" \
      > "$META_CAPTURE_TMP" || die "cannot capture task metadata: $meta"
  else
    python3 "$FS_OWNER" snapshot-path "$meta" "$MAX_BYTES" > "$META_CAPTURE_TMP" \
      || die "cannot capture task metadata: $meta"
  fi
  safe_regular_file "$META_CAPTURE_TMP" "captured task metadata"
  META_CAPTURE_SOURCE=$meta
}

finish_metadata_capture() {  # <meta>
  local meta=$1 details current
  [ "$META_CAPTURE_SOURCE" = "$meta" ] || die "task metadata capture ownership is mismatched: $meta"
  if [ -n "$META_CAPTURE_PARENT" ]; then
    details=$(python3 "$FS_OWNER" describe-digest \
      "$META_CAPTURE_PARENT" "$META_CAPTURE_PARENT_ID" "$META_CAPTURE_BASE") \
      || die "cannot reinspect task metadata: $meta"
    [ "$details" = "$META_CAPTURE_ENTRY_STATE"$'\t'"$META_CAPTURE_ENTRY_DIGEST" ] \
      || die "task metadata changed while it was validated: $meta"
  else
    current=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-meta-check.XXXXXX") \
      || die "cannot recapture task metadata: $meta"
    python3 "$FS_OWNER" snapshot-path "$meta" "$MAX_BYTES" > "$current" \
      || { rm -f -- "$current"; die "task metadata changed while it was validated: $meta"; }
    cmp -s "$META_CAPTURE_TMP" "$current" \
      || { rm -f -- "$current"; die "task metadata changed while it was validated: $meta"; }
    rm -f -- "$current"
  fi
  rm -f -- "$META_CAPTURE_TMP"
  META_CAPTURE_TMP=
  META_CAPTURE_SOURCE=
  META_CAPTURE_PARENT=
  META_CAPTURE_PARENT_ID=
  META_CAPTURE_BASE=
  META_CAPTURE_ENTRY_STATE=
  META_CAPTURE_ENTRY_DIGEST=
}

meta_field_exact() {  # <meta> <key>; sets META_VALUE, 0 exact, 1 absent, 2 malformed
  local meta=$1 key=$2 input=$1 count
  if [ -n "$META_CAPTURE_SOURCE" ] && [ "$meta" = "$META_CAPTURE_SOURCE" ]; then
    input=$META_CAPTURE_TMP
  fi
  count=$(grep -c "^${key}=" "$input" 2>/dev/null || true)
  case "$count" in
    0) META_VALUE=; return 1 ;;
    1) META_VALUE=$(grep "^${key}=" "$input" | cut -d= -f2-); return 0 ;;
    *) META_VALUE=; return 2 ;;
  esac
}

validate_optional_dispatch_metadata_receipt() {  # <meta>
  local meta=$1 rc=0 transaction
  meta_field_exact "$meta" work_identity_dispatch_transaction || rc=$?
  case "$rc" in
    1) return 0 ;;
    2) die "task metadata has duplicate work identity dispatch transactions: $meta" ;;
  esac
  transaction=$META_VALUE
  [ -n "$LOCATED_TASK" ] || die "task metadata dispatch binding has no owning task: $meta"
  [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ] \
    || die "task metadata dispatch transaction has no exact owner receipt: $meta"
  read_dispatch_state "$LOCATED_TASK"
  [ "$transaction" = "$DISPATCH_TRANSACTION" ] \
    || die "task metadata work identity dispatch transaction is stale or mismatched: $meta"
}

validate_meta_binding_captured() {  # <meta> <linked|unlinked> [hash] [brief-hash] [brief-path]
  local meta=$1 expected=$2 hash=${3:-} brief_hash=${4:-${BRIEF_HASH:-}} brief_path=${5:-} status schema recorded_hash recorded_brief_hash recorded_brief_path rc
  validate_optional_dispatch_metadata_receipt "$meta"
  rc=0; meta_field_exact "$meta" work_identity_status || rc=$?
  if [ "$rc" -eq 1 ]; then
    meta_field_exact "$meta" work_identity_schema >/dev/null 2>&1 && die "task metadata has a work identity schema without status: $meta"
    meta_field_exact "$meta" work_identity_sha256 >/dev/null 2>&1 && die "task metadata has a work identity digest without status: $meta"
    meta_field_exact "$meta" launch_brief_sha256 >/dev/null 2>&1 && die "task metadata has a launch brief digest without work identity status: $meta"
    [ "$expected" = unlinked ] || die "linked work identity is not bound by task metadata: $meta"
    META_PROVENANCE=legacy
    return 0
  fi
  [ "$rc" -eq 0 ] || die "task metadata has duplicate work identity status fields: $meta"
  status=$META_VALUE
  meta_field_exact "$meta" work_identity_schema || die "task metadata has no exact work identity schema: $meta"
  schema=$META_VALUE
  [ "$schema" = "$SCHEMA" ] || die "task metadata work identity schema mismatch: $meta"
  [ "$status" = "$expected" ] || die "task metadata work identity status mismatch: $meta"
  if [ "$expected" = linked ]; then
    meta_field_exact "$meta" work_identity_sha256 || die "linked task metadata has no exact work identity digest: $meta"
    recorded_hash=$META_VALUE
    [ "$recorded_hash" = "$hash" ] || die "stale work identity digest in task metadata: $meta"
  else
    rc=0; meta_field_exact "$meta" work_identity_sha256 || rc=$?
    [ "$rc" -eq 1 ] || die "unlinked task metadata must not carry a work identity digest: $meta"
  fi
  rc=0; meta_field_exact "$meta" launch_brief_sha256 || rc=$?
  case "$rc" in
    0)
      recorded_brief_hash=$META_VALUE
      [ -n "$brief_hash" ] && [ "$recorded_brief_hash" = "$brief_hash" ] \
        || die "stale or mismatched launch brief digest in task metadata: $meta"
      ;;
    1) [ -z "$brief_path" ] || die "task metadata has no launch brief digest: $meta" ;;
    *) die "task metadata has duplicate launch brief digest fields: $meta" ;;
  esac
  if [ -n "$brief_path" ]; then
    meta_field_exact "$meta" launch_brief \
      || die "task metadata has no exact launch brief path: $meta"
    recorded_brief_path=$META_VALUE
    [ "$recorded_brief_path" = "$brief_path" ] \
      || die "task metadata launch brief path mismatch: $meta"
  fi
  META_PROVENANCE=metadata
}

validate_meta_binding() {  # <meta> <linked|unlinked> [hash] [brief-hash] [brief-path]
  local meta=$1 owned=0
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  if [ "$META_CAPTURE_SOURCE" != "$meta" ]; then
    capture_metadata "$meta"
    owned=1
  fi
  validate_meta_binding_captured "$@"
  [ "$owned" -eq 0 ] || finish_metadata_capture "$meta"
}

brief_contract_count() {  # <brief>
  grep -c '^Work identity contract:' "$1" 2>/dev/null || true
}

finish_brief_capture() {
  BRIEF_HASH=$(sha256_file "$BRIEF_INPUT_TMP") || die "SHA-256 is unavailable for generated instructions"
  case "$BRIEF_HASH" in ''|*[!A-Fa-f0-9]*) die "generated instructions SHA-256 is invalid" ;; esac
  [ "${#BRIEF_HASH}" -eq 64 ] || die "generated instructions SHA-256 has the wrong length"
  BRIEF_HASH=$(printf '%s' "$BRIEF_HASH" | tr 'A-F' 'a-f')
  if [ "$RETAIN_BRIEF_CAPTURE" -eq 1 ]; then
    BRIEF_VALIDATED_CAPTURE=$BRIEF_INPUT_TMP
    BRIEF_INPUT_TMP=
  else
    rm -f -- "$BRIEF_INPUT_TMP"
    BRIEF_INPUT_TMP=
  fi
}

validate_brief_binding() {  # <brief> <linked|unlinked> [hash] [canonical]
  local brief=$1 expected=$2 hash=${3:-} canonical=${4:-} count marker payload_count expected_marker
  BRIEF_HASH=
  [ -e "$brief" ] || [ -L "$brief" ] || { BRIEF_PROVENANCE=absent; return 0; }
  BRIEF_INPUT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-brief.XXXXXX") \
    || die "cannot capture generated instructions"
  python3 "$FS_OWNER" snapshot-path "$brief" "$MAX_BYTES" > "$BRIEF_INPUT_TMP" \
    || die "cannot capture generated instructions: $brief"
  safe_regular_file "$BRIEF_INPUT_TMP" "captured generated instructions"
  count=$(brief_contract_count "$BRIEF_INPUT_TMP")
  if [ "$count" = 0 ]; then
    [ "$expected" = unlinked ] || die "linked work identity is missing from generated instructions: $brief"
    BRIEF_PROVENANCE=legacy
    finish_brief_capture
    return 0
  fi
  [ "$count" = 1 ] || die "generated instructions contain duplicate work identity contracts: $brief"
  marker=$(grep '^Work identity contract:' "$BRIEF_INPUT_TMP")
  if [ "$expected" = linked ]; then
    expected_marker="Work identity contract: $SCHEMA sha256=$hash"
    [ "$marker" = "$expected_marker" ] || die "stale or mismatched work identity contract in generated instructions: $brief"
    payload_count=$(grep -c '^Work identity payload: ' "$BRIEF_INPUT_TMP" 2>/dev/null || true)
    [ "$payload_count" = 1 ] || die "generated instructions require one exact work identity payload: $brief"
    [ "$(grep '^Work identity payload: ' "$BRIEF_INPUT_TMP")" = "Work identity payload: $canonical" ] \
      || die "stale or mismatched work identity payload in generated instructions: $brief"
  else
    [ "$marker" = "Work identity contract: $SCHEMA unlinked" ] \
      || die "generated instructions claim a linked or unknown work identity without a record: $brief"
    payload_count=$(grep -c '^Work identity payload: ' "$BRIEF_INPUT_TMP" 2>/dev/null || true)
    [ "$payload_count" = 0 ] || die "unlinked generated instructions must not carry a work identity payload: $brief"
  fi
  BRIEF_PROVENANCE=generated-instructions
  finish_brief_capture
}

validate_home_literal() {  # <absolute-home>
  local home=$1
  case "$home" in /*) ;; *) die "work identity home must be absolute: $home" ;; esac
  case "/$home/" in */../*|*/./*) die "work identity home contains traversal: $home" ;; esac
  case "$home" in *'//'*) die "work identity home contains an empty path component: $home" ;; esac
  case "$home" in *$'\n'*|*$'\r'*|*$'\t'*) die "work identity home contains control characters" ;; esac
}

capture_contract_input() {  # <path|-> <label> <max-bytes>; sets CONTRACT_INPUT/CONTRACT_INPUT_TMP
  local path=$1 label=$2 max=$3 bytes
  CONTRACT_INPUT_TMP=
  if [ "$path" = - ]; then
    CONTRACT_INPUT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-input.XXXXXX") \
      || die "cannot create $label temporary file"
    head -c "$((max + 1))" > "$CONTRACT_INPUT_TMP" \
      || { rm -f -- "$CONTRACT_INPUT_TMP"; CONTRACT_INPUT_TMP=; die "cannot read $label"; }
    bytes=$(file_size "$CONTRACT_INPUT_TMP") || die "cannot inspect $label size"
    [ "$bytes" -le "$max" ] || die "$label exceeds $max bytes"
    CONTRACT_INPUT=$CONTRACT_INPUT_TMP
  else
    safe_regular_file "$path" "$label" "$max"
    CONTRACT_INPUT=$path
  fi
}

validate_projection_index() {  # <path>
  local path=$1 row task
  safe_regular_file "$path" "work identity projection index" "$MAX_PROJECTION_BATCH_BYTES"
  jq -e --arg schema "$SCHEMA" '
    . as $entries
    | ($entries | type) == "array"
    and (($entries | map(.task_id) | unique | length) == ($entries | length))
    and all($entries[];
      type == "object"
      and (keys | sort) == (["schema","sha256","status","task_id"] | sort)
      and (.task_id | type) == "string"
      and .schema == $schema
      and ((.status == "linked" and (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
        or (.status == "unlinked" and .sha256 == null)))
  ' "$path" >/dev/null 2>&1 || die "projection index does not satisfy $SCHEMA"
  while IFS= read -r row; do
    task=$(printf '%s' "$row" | jq -er '.task_id') || die "projection index task id is malformed"
    fm_pr_task_id_valid "$task" || die "projection index has an invalid task id"
    printf '%s\n' "$task"
  done < <(jq -c '.[]' "$path")
}

validate_projection_set() {  # <path> <expected-home> <expected-home-id>
  local path=$1 expected_home=$2 expected_home_id=$3 row task status recorded_hash canonical tmp
  validate_home_literal "$expected_home"
  home_id_literal_valid "$expected_home_id" || die "projection home id is malformed"
  safe_regular_file "$path" "work identity projection set" "$MAX_PROJECTION_BATCH_BYTES"
  jq -e '
    . as $entries
    | ($entries | type) == "array"
    and (($entries | map(.task_id) | unique | length) == ($entries | length))
    and all($entries[];
      type == "object"
      and (keys | sort) == (["task_id","work_identity"] | sort)
      and (.task_id | type) == "string"
      and (.work_identity | type) == "object")
  ' "$path" >/dev/null 2>&1 || die "projection set does not satisfy $SCHEMA"
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-projection.XXXXXX") \
    || die "cannot create projection validation file"
  while IFS= read -r row; do
    task=$(printf '%s' "$row" | jq -er '.task_id') \
      || { rm -f -- "$tmp"; die "projection task id is malformed"; }
    fm_pr_task_id_valid "$task" \
      || { rm -f -- "$tmp"; die "projection has an invalid task id"; }
    status=$(printf '%s' "$row" | jq -er '.work_identity.status') \
      || { rm -f -- "$tmp"; die "projection status is malformed"; }
    case "$status" in
      linked)
        printf '%s' "$row" | jq -e -S -c \
          --arg schema "$SCHEMA" --arg home "$expected_home" --arg home_id "$expected_home_id" --arg task "$task" '
          .work_identity as $w
          | select(($w | keys | sort) == (["binding","initiative","plan_id","provenance","schema","sha256","sources","stage","status","work_units"] | sort))
          | select($w.status == "linked" and $w.schema == $schema)
          | select($w.binding == {home:$home,home_id:$home_id,task_id:$task})
          | select(($w.sha256 | type) == "string" and ($w.sha256 | test("^[0-9a-f]{64}$")))
          | select(($w.provenance | type) == "object"
              and ($w.provenance | keys | sort) == (["instructions","metadata","record"] | sort)
              and $w.provenance.record == "intake-sidecar"
              and (["absent","legacy","generated-instructions"] | index($w.provenance.instructions)) != null
              and (["absent","legacy","metadata"] | index($w.provenance.metadata)) != null)
          | {schema:$w.schema,binding:$w.binding,initiative:$w.initiative,plan_id:$w.plan_id,
             stage:$w.stage,work_units:$w.work_units,sources:$w.sources}
        ' > "$tmp" 2>/dev/null \
          || { rm -f -- "$tmp"; die "linked projection does not satisfy $SCHEMA"; }
        canonical=$(canonicalize_manifest "$tmp" "$task" "$expected_home" "$expected_home_id")
        printf '%s\n' "$canonical" | cmp -s "$tmp" - \
          || { rm -f -- "$tmp"; die "linked projection is not canonical"; }
        WORK_HASH=$(sha256_file "$tmp") || { rm -f -- "$tmp"; die "SHA-256 is unavailable for linked projection"; }
        recorded_hash=$(printf '%s' "$row" | jq -er '.work_identity.sha256') \
          || { rm -f -- "$tmp"; die "linked projection digest is malformed"; }
        [ "$WORK_HASH" = "$recorded_hash" ] \
          || { rm -f -- "$tmp"; die "linked projection digest is stale or mismatched"; }
        ;;
      unlinked)
        printf '%s' "$row" | jq -e \
          --arg schema "$SCHEMA" --arg home "$expected_home" --arg home_id "$expected_home_id" --arg task "$task" '
          .work_identity as $w
          | ($w | keys | sort) == (["binding","initiative","plan_id","provenance","reason","schema","sha256","sources","stage","status","work_units"] | sort)
          and $w.status == "unlinked" and $w.schema == $schema and $w.sha256 == null
          and $w.binding == {home:$home,home_id:$home_id,task_id:$task}
          and $w.initiative == null and $w.plan_id == null and $w.stage == null
          and $w.work_units == [] and $w.sources == []
          and (["explicitly-unlinked","legacy-no-record"] | index($w.reason)) != null
          and ($w.provenance | type) == "object"
          and ($w.provenance | keys | sort) == (["instructions","metadata","record"] | sort)
          and $w.provenance.record == "absent"
          and (["absent","legacy","generated-instructions"] | index($w.provenance.instructions)) != null
          and (["absent","legacy","metadata"] | index($w.provenance.metadata)) != null
        ' >/dev/null 2>&1 || { rm -f -- "$tmp"; die "unlinked projection does not satisfy $SCHEMA"; }
        ;;
      *) rm -f -- "$tmp"; die "projection status does not satisfy $SCHEMA" ;;
    esac
  done < <(jq -c '.[]' "$path")
  rm -f -- "$tmp"
}

owned_lock_acquire() {  # <directory> <inode> <name> <token> <label>
  local directory=$1 inode=$2 name=$3 token=$4 label=$5 rc stale=${FM_LOCK_STALE_AFTER:-2}
  while :; do
    rc=0
    python3 "$FS_OWNER" lock-try "$directory" "$inode" "$name" \
      "${BASHPID:-$$}" "$token" "$stale" >/dev/null || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) sleep 0.1 ;;
      *) die "$label lock path is unsafe or was replaced: $directory/$name" ;;
    esac
  done
}

publication_lock_acquire() {
  [ "$ACTIVE_PUBLICATION_LOCK_HELD" -eq 0 ] || return 0
  ensure_data_dir
  lock_parent_preflight "$DATA_REAL" "work identity publication"
  ACTIVE_PUBLICATION_LOCK=.work-identity-publication.lock
  ACTIVE_PUBLICATION_LOCK_PARENT=$DATA_REAL
  ACTIVE_PUBLICATION_LOCK_PARENT_ID=$DATA_DIR_ID
  if [ -n "${FM_WORK_IDENTITY_BATCH_LOCK_PID:-}" ] \
     || [ -n "${FM_WORK_IDENTITY_BATCH_LOCK_TOKEN:-}" ]; then
    case "${FM_WORK_IDENTITY_BATCH_LOCK_PID:-}" in ''|*[!0-9]*) die "delegated work identity lock owner is malformed" ;; esac
    case "${FM_WORK_IDENTITY_BATCH_LOCK_TOKEN:-}" in ''|*[!A-Za-z0-9._:-]*) die "delegated work identity lock token is malformed" ;; esac
    python3 "$FS_OWNER" lock-held "$ACTIVE_PUBLICATION_LOCK_PARENT" \
      "$ACTIVE_PUBLICATION_LOCK_PARENT_ID" "$ACTIVE_PUBLICATION_LOCK" \
      "$FM_WORK_IDENTITY_BATCH_LOCK_PID" "$FM_WORK_IDENTITY_BATCH_LOCK_TOKEN" \
      || die "delegated work identity publication lock is absent or mismatched"
    ACTIVE_PUBLICATION_LOCK_TOKEN=$FM_WORK_IDENTITY_BATCH_LOCK_TOKEN
    ACTIVE_PUBLICATION_LOCK_EXTERNAL=1
  else
    ACTIVE_PUBLICATION_LOCK_TOKEN="publication-${BASHPID:-$$}-${RANDOM}-${RANDOM}"
    owned_lock_acquire "$ACTIVE_PUBLICATION_LOCK_PARENT" "$ACTIVE_PUBLICATION_LOCK_PARENT_ID" \
      "$ACTIVE_PUBLICATION_LOCK" "$ACTIVE_PUBLICATION_LOCK_TOKEN" "work identity publication"
  fi
  ACTIVE_PUBLICATION_LOCK_HELD=1
}

identity_lock_acquire() {  # <task-id>
  local task=$1 lock_key
  ensure_state_dir
  lock_parent_preflight "$STATE_REAL" "work identity task"
  lock_key=$(printf '%s' "$task" | sha256_stream) \
    || die "SHA-256 is unavailable for work identity task lock"
  case "$lock_key" in ''|*[!A-Fa-f0-9]*) die "work identity task lock digest is invalid" ;; esac
  [ "${#lock_key}" -eq 64 ] || die "work identity task lock digest has the wrong length"
  ACTIVE_IDENTITY_LOCK=".work-identity-task-${lock_key}.lock"
  ACTIVE_IDENTITY_LOCK_PARENT=$STATE_REAL
  ACTIVE_IDENTITY_LOCK_PARENT_ID=$STATE_DIR_ID
  if [ -n "${FM_WORK_IDENTITY_BATCH_LOCK_PID:-}" ] \
     || [ -n "${FM_WORK_IDENTITY_BATCH_LOCK_TOKEN:-}" ] \
     || [ -n "${FM_WORK_IDENTITY_BATCH_LOCK_TASKS:-}" ]; then
    case "${FM_WORK_IDENTITY_BATCH_LOCK_PID:-}" in ''|*[!0-9]*) die "delegated work identity lock owner is malformed" ;; esac
    case "${FM_WORK_IDENTITY_BATCH_LOCK_TOKEN:-}" in ''|*[!A-Za-z0-9._:-]*) die "delegated work identity lock token is malformed" ;; esac
    case $'\n'"${FM_WORK_IDENTITY_BATCH_LOCK_TASKS:-}"$'\n' in
      *$'\n'"$task"$'\n'*) ;;
      *) die "delegated work identity task lock does not authorize $task" ;;
    esac
    python3 "$FS_OWNER" lock-held "$ACTIVE_IDENTITY_LOCK_PARENT" \
      "$ACTIVE_IDENTITY_LOCK_PARENT_ID" "$ACTIVE_IDENTITY_LOCK" \
      "$FM_WORK_IDENTITY_BATCH_LOCK_PID" "$FM_WORK_IDENTITY_BATCH_LOCK_TOKEN" \
      || die "delegated work identity task lock is absent or mismatched for $task"
    ACTIVE_IDENTITY_LOCK_TOKEN=$FM_WORK_IDENTITY_BATCH_LOCK_TOKEN
    ACTIVE_IDENTITY_LOCK_EXTERNAL=1
  else
    ACTIVE_IDENTITY_LOCK_TOKEN="task-${BASHPID:-$$}-${RANDOM}-${RANDOM}"
    owned_lock_acquire "$ACTIVE_IDENTITY_LOCK_PARENT" "$ACTIVE_IDENTITY_LOCK_PARENT_ID" \
      "$ACTIVE_IDENTITY_LOCK" "$ACTIVE_IDENTITY_LOCK_TOKEN" "work identity task"
  fi
  ACTIVE_IDENTITY_LOCK_HELD=1
  locate_task_dir "$task"
  if [ -d "$TASK_DIR" ]; then
    recover_no_clobber_publications
    recover_owned_replacement "$SOURCE_HANDOFF" "source handoff state"
    recover_owned_replacement "$TARGET_HANDOFF" "target handoff state"
    recover_owned_replacement "$DISPATCH_STATE" "dispatch state"
    recover_owned_replacement "$DISPATCH_PRIOR" "retained dispatch instructions"
    recover_owned_replacement "$UNLINKED_RESERVATION" "unlinked reservation"
  fi
  if [ "${#task}" -le 220 ]; then
    recover_owned_replacement "$STATE_REAL/$task.launch-brief.md" "dispatch instructions"
    recover_owned_replacement "$STATE_REAL/$task.meta" "task metadata"
  fi
}

identity_lock_release() {
  [ "$ACTIVE_IDENTITY_LOCK_HELD" -eq 1 ] || return 0
  if [ "$ACTIVE_IDENTITY_LOCK_EXTERNAL" -ne 1 ]; then
    python3 "$FS_OWNER" lock-release "$ACTIVE_IDENTITY_LOCK_PARENT" \
      "$ACTIVE_IDENTITY_LOCK_PARENT_ID" "$ACTIVE_IDENTITY_LOCK" \
      "${BASHPID:-$$}" "$ACTIVE_IDENTITY_LOCK_TOKEN" \
      || die "cannot release work identity task lock"
  fi
  ACTIVE_IDENTITY_LOCK_HELD=0
  ACTIVE_IDENTITY_LOCK_EXTERNAL=0
  ACTIVE_IDENTITY_LOCK=
  ACTIVE_IDENTITY_LOCK_PARENT=
  ACTIVE_IDENTITY_LOCK_PARENT_ID=
  ACTIVE_IDENTITY_LOCK_TOKEN=
}

identity_mutation_lock_acquire() {  # <task-id>
  publication_lock_acquire
  identity_lock_acquire "$1"
  ensure_task_dir "$1"
}

validate_handoff_envelope() {  # <path> <task-id>; sets HANDOFF_*
  local path=$1 task=$2 canonical source_task target_task material computed record validated_record record_hash
  canonical=$(jq -e -S -c -s --arg schema "$HANDOFF_SCHEMA" '
    def exact_keys($ks): (keys | sort) == ($ks | sort);
    select(length == 1) | .[0] | . as $transfer | select(
    type == "object" and exact_keys(["schema","transfer_id","source","target","backlog","identity"])
    and .schema == $schema
    and (.transfer_id | type == "string" and test("^[0-9a-f]{64}$"))
    and (.source | type == "object" and exact_keys(["home","home_id","task_id"])
      and (.home | type) == "string" and (.home_id | type) == "string" and (.task_id | type) == "string")
    and (.target | type == "object" and exact_keys(["home","home_id","task_id"])
      and (.home | type) == "string" and (.home_id | type) == "string" and (.task_id | type) == "string")
    and (.backlog | type == "object" and exact_keys(["task_sha256"])
      and (.task_sha256 == null or (.task_sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
    and (.identity | type == "object" and exact_keys(["status","source_sha256","target_sha256","record"])
      and ((.status == "linked"
            and (.source_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.target_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.record | type) == "object")
        or (.status == "unlinked" and .source_sha256 == null
            and .target_sha256 == null and .record == null)))
    ) | $transfer
  ' "$path" 2>/dev/null) || die "handoff transfer does not satisfy $HANDOFF_SCHEMA"
  printf '%s\n' "$canonical" | cmp -s "$path" - \
    || die "handoff transfer is not canonical or has trailing data"
  HANDOFF_TRANSFER_ID=$(printf '%s' "$canonical" | jq -r '.transfer_id')
  HANDOFF_SOURCE_HOME=$(printf '%s' "$canonical" | jq -r '.source.home')
  HANDOFF_SOURCE_HOME_ID=$(printf '%s' "$canonical" | jq -r '.source.home_id')
  HANDOFF_TARGET_HOME=$(printf '%s' "$canonical" | jq -r '.target.home')
  HANDOFF_TARGET_HOME_ID=$(printf '%s' "$canonical" | jq -r '.target.home_id')
  source_task=$(printf '%s' "$canonical" | jq -r '.source.task_id')
  target_task=$(printf '%s' "$canonical" | jq -r '.target.task_id')
  [ "$source_task" = "$task" ] && [ "$target_task" = "$task" ] \
    || die "handoff transfer task binding is mismatched"
  fm_pr_task_id_valid "$task" || die "handoff transfer task id is invalid"
  validate_home_literal "$HANDOFF_SOURCE_HOME"
  validate_home_literal "$HANDOFF_TARGET_HOME"
  home_id_literal_valid "$HANDOFF_SOURCE_HOME_ID" || die "handoff source home id is malformed"
  home_id_literal_valid "$HANDOFF_TARGET_HOME_ID" || die "handoff target home id is malformed"
  [ "$HANDOFF_SOURCE_HOME" != "$HANDOFF_TARGET_HOME" ] \
    || [ "$HANDOFF_SOURCE_HOME_ID" != "$HANDOFF_TARGET_HOME_ID" ] \
    || die "handoff source and target identities match"
  HANDOFF_BACKLOG_SHA=$(printf '%s' "$canonical" | jq -r '.backlog.task_sha256 // ""')
  HANDOFF_STATUS=$(printf '%s' "$canonical" | jq -r '.identity.status')
  HANDOFF_SOURCE_SHA=$(printf '%s' "$canonical" | jq -r '.identity.source_sha256 // ""')
  HANDOFF_TARGET_SHA=$(printf '%s' "$canonical" | jq -r '.identity.target_sha256 // ""')
  HANDOFF_RECORD=
  if [ "$HANDOFF_STATUS" = linked ]; then
    record=$(printf '%s' "$canonical" | jq -S -c '.identity.record') \
      || die "handoff linked record is malformed"
    validated_record=$(canonicalize_manifest <(printf '%s\n' "$record") "$task" \
      "$HANDOFF_TARGET_HOME" "$HANDOFF_TARGET_HOME_ID")
    [ "$validated_record" = "$record" ] || die "handoff linked record is not canonical"
    record_hash=$(printf '%s\n' "$record" | sha256_stream) \
      || die "SHA-256 is unavailable for handoff linked record"
    [ "$record_hash" = "$HANDOFF_TARGET_SHA" ] \
      || die "handoff target digest is stale or mismatched"
    HANDOFF_RECORD=$record
  fi
  material=$(printf '%s' "$canonical" | jq -S -c 'del(.transfer_id)') \
    || die "cannot canonicalize handoff transfer commitment"
  computed=$(printf '%s\n' "$material" | sha256_stream) \
    || die "SHA-256 is unavailable for handoff transfer"
  [ "$computed" = "$HANDOFF_TRANSFER_ID" ] || die "handoff transfer commitment is mismatched"
  HANDOFF_CANONICAL=$canonical
}

validate_handoff_text() {  # <canonical-transfer> <task-id>
  local text=$1 task=$2
  VALIDATION_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-transfer.XXXXXX") \
    || die "cannot create handoff transfer validation file"
  printf '%s\n' "$text" > "$VALIDATION_TMP" || die "cannot write handoff transfer validation file"
  validate_handoff_envelope "$VALIDATION_TMP" "$task"
  rm -f -- "$VALIDATION_TMP"
  VALIDATION_TMP=
}

handoff_state_json() {  # <source|target> <prepared|completed> <transfer>
  jq -n -S -c --arg schema "$HANDOFF_STATE_SCHEMA" --arg role "$1" --arg state "$2" \
    --argjson transfer "$3" '{schema:$schema,role:$role,state:$state,transfer:$transfer}'
}

read_handoff_state() {  # <path> <source|target> <task-id>; sets HANDOFF_STATE/HANDOFF_TRANSFER
  local path=$1 role=$2 task=$3 wrapper transfer
  IFS=$'\t' read -r HANDOFF_STATE_ENTRY_STATE HANDOFF_STATE_ENTRY_DIGEST \
    < <(owned_removal_expectation "$path" "work identity handoff state") \
    || die "cannot bind validated work identity handoff state"
  safe_regular_file "$path" "work identity handoff state" "$HANDOFF_MAX_BYTES"
  wrapper=$(jq -e -S -c -s --arg schema "$HANDOFF_STATE_SCHEMA" --arg role "$role" '
    def exact_keys($ks): (keys | sort) == ($ks | sort);
    select(length == 1) | .[0] | . as $wrapper | select(
    type == "object" and exact_keys(["schema","role","state","transfer"])
    and .schema == $schema and .role == $role
    and (if $role == "source" then (.state == "prepared" or .state == "completed")
         else (.state == "prepared" or .state == "backlog-prepared"
           or .state == "backlog-completed" or .state == "completed"
           or .state == "intake-prepared" or .state == "intake-completed") end)
    and (.transfer | type) == "object"
    ) | $wrapper
  ' "$path" 2>/dev/null) || die "work identity handoff state is malformed: $path"
  printf '%s\n' "$wrapper" | cmp -s "$path" - \
    || die "work identity handoff state is not canonical: $path"
  transfer=$(printf '%s' "$wrapper" | jq -S -c '.transfer')
  validate_handoff_text "$transfer" "$task"
  HANDOFF_STATE=$(printf '%s' "$wrapper" | jq -r '.state')
  HANDOFF_TRANSFER=$HANDOFF_CANONICAL
}

write_handoff_state() {  # <path> <source|target> <prepared|completed> <transfer>
  local path=$1 role=$2 state=$3 transfer=$4 payload
  payload=$(handoff_state_json "$role" "$state" "$transfer") \
    || die "cannot build work identity handoff state"
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-handoff.XXXXXX") \
    || die "cannot create work identity handoff state"
  printf '%s\n' "$payload" > "$TMP" || die "cannot write work identity handoff state"
  chmod 600 "$TMP" || die "cannot protect work identity handoff state"
  owned_atomic_replace "$TMP" "$path" "work identity handoff state"
  TMP=
}

dispatch_transaction_valid() {
  case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

dispatch_instructions_path_valid() {
  local path=$1 parent
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  parent=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  [ "$parent" = "$STATE_REAL" ]
}

read_unlinked_guard() {  # <task-id>
  local task=$1 wrapper
  ensure_home_identity
  safe_regular_file "$UNLINKED_GUARD" "work identity unlinked guard" "$HANDOFF_MAX_BYTES"
  wrapper=$(jq -e -S -c -s \
    --arg schema "$UNLINKED_GUARD_SCHEMA" --arg home "$FM_HOME_REAL" \
    --arg home_id "$FM_HOME_ID" --arg task "$task" '
      def exact_keys($ks): (keys | sort) == ($ks | sort);
      select(length == 1) | .[0] | select(
        type == "object" and exact_keys(["schema","binding","reason"])
        and .schema == $schema
        and .binding == {home:$home,home_id:$home_id,task_id:$task}
        and .reason == "persistent-secondmate")
    ' "$UNLINKED_GUARD" 2>/dev/null) \
    || die "work identity unlinked guard is malformed or mismatched: $UNLINKED_GUARD"
  printf '%s\n' "$wrapper" | cmp -s "$UNLINKED_GUARD" - \
    || die "work identity unlinked guard is not canonical: $UNLINKED_GUARD"
  [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] \
    || die "unlinked work identity guard conflicts with a linked record for task $task"
}

validate_unlinked_guard() {  # <task-id>
  if [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ]; then
    ensure_home_identity
    read_unlinked_guard "$1"
  fi
}

write_unlinked_guard() {  # <task-id> <reason>
  local task=$1 reason=$2 payload
  ensure_home_identity
  payload=$(jq -n -S -c --arg schema "$UNLINKED_GUARD_SCHEMA" \
    --arg home "$FM_HOME_REAL" --arg home_id "$FM_HOME_ID" --arg task "$task" \
    --arg reason "$reason" \
    '{schema:$schema,binding:{home:$home,home_id:$home_id,task_id:$task},reason:$reason}') \
    || die "cannot build work identity unlinked guard"
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-unlinked-guard.XXXXXX") \
    || die "cannot create work identity unlinked guard"
  printf '%s\n' "$payload" > "$TMP" || die "cannot write work identity unlinked guard"
  chmod 600 "$TMP" || die "cannot protect work identity unlinked guard"
  if ! publish_no_clobber "$TMP" "$UNLINKED_GUARD" "work identity unlinked guard"; then
    [ -z "$TMP" ] || rm -f -- "$TMP"
    TMP=
    [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ] \
      || die "cannot publish work identity unlinked guard"
  fi
  read_unlinked_guard "$task"
}

read_unlinked_reservation() {  # <task-id>
  local task=$1 wrapper
  ensure_home_identity
  IFS=$'\t' read -r UNLINKED_RESERVATION_ENTRY_STATE UNLINKED_RESERVATION_ENTRY_DIGEST \
    < <(owned_removal_expectation "$UNLINKED_RESERVATION" "work identity unlinked reservation") \
    || die "cannot bind validated work identity unlinked reservation"
  safe_regular_file "$UNLINKED_RESERVATION" "work identity unlinked reservation" "$HANDOFF_MAX_BYTES"
  wrapper=$(jq -e -S -c -s \
    --arg schema "$UNLINKED_RESERVATION_SCHEMA" --arg home "$FM_HOME_REAL" \
    --arg home_id "$FM_HOME_ID" --arg task "$task" '
      def exact_keys($ks): (keys | sort) == ($ks | sort);
      select(length == 1) | .[0] | select(
        type == "object" and exact_keys(["schema","state","transaction_id","binding","reason"])
        and .schema == $schema and .state == "prepared"
        and (.transaction_id | type) == "string"
        and .binding == {home:$home,home_id:$home_id,task_id:$task}
        and .reason == "persistent-secondmate")
    ' "$UNLINKED_RESERVATION" 2>/dev/null) \
    || die "work identity unlinked reservation is malformed or mismatched: $UNLINKED_RESERVATION"
  printf '%s\n' "$wrapper" | cmp -s "$UNLINKED_RESERVATION" - \
    || die "work identity unlinked reservation is not canonical: $UNLINKED_RESERVATION"
  UNLINKED_RESERVATION_TRANSACTION=$(printf '%s' "$wrapper" | jq -r '.transaction_id')
  dispatch_transaction_valid "$UNLINKED_RESERVATION_TRANSACTION" \
    || die "work identity unlinked reservation transaction is malformed"
  [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] \
    || die "unlinked work identity reservation conflicts with a linked record for task $task"
}

validate_unlinked_reservation() {  # <task-id>
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    ensure_home_identity
    read_unlinked_reservation "$1"
  fi
}

write_unlinked_reservation() {  # <task-id> <reason> <transaction>
  local task=$1 reason=$2 transaction=$3 payload
  ensure_home_identity
  payload=$(jq -n -S -c --arg schema "$UNLINKED_RESERVATION_SCHEMA" \
    --arg home "$FM_HOME_REAL" --arg home_id "$FM_HOME_ID" --arg task "$task" \
    --arg reason "$reason" --arg transaction "$transaction" \
    '{schema:$schema,state:"prepared",transaction_id:$transaction,
      binding:{home:$home,home_id:$home_id,task_id:$task},reason:$reason}') \
    || die "cannot build work identity unlinked reservation"
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-unlinked-reservation.XXXXXX") \
    || die "cannot create work identity unlinked reservation"
  printf '%s\n' "$payload" > "$TMP" || die "cannot write work identity unlinked reservation"
  chmod 600 "$TMP" || die "cannot protect work identity unlinked reservation"
  if ! publish_no_clobber "$TMP" "$UNLINKED_RESERVATION" "work identity unlinked reservation"; then
    [ -z "$TMP" ] || rm -f -- "$TMP"
    TMP=
    [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ] \
      || die "cannot publish work identity unlinked reservation"
  fi
  read_unlinked_reservation "$task"
  [ "$UNLINKED_RESERVATION_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different unlinked reservation"
}

read_dispatch_state() {  # <task-id>
  local task=$1 wrapper
  IFS=$'\t' read -r DISPATCH_STATE_ENTRY_STATE DISPATCH_STATE_ENTRY_DIGEST \
    < <(owned_removal_expectation "$DISPATCH_STATE" "work identity dispatch state") \
    || die "cannot bind validated work identity dispatch state"
  safe_regular_file "$DISPATCH_STATE" "work identity dispatch state" "$HANDOFF_MAX_BYTES"
  wrapper=$(jq -e -S -c -s --arg schema "$DISPATCH_STATE_SCHEMA" --arg contract "$SCHEMA" --arg task "$task" '
    def exact_keys($ks): (keys | sort) == ($ks | sort);
    select(length == 1) | .[0] | . as $wrapper | select(
      type == "object"
      and exact_keys(["schema","state","transaction_id","binding","instructions","identity","replacement","previous_transaction_id","previous_instructions_sha256"])
      and .schema == $schema and (.state == "prepared" or .state == "completed")
      and (.transaction_id | type) == "string"
      and (.binding | type == "object" and exact_keys(["home","home_id","task_id"])
        and (.home | type) == "string" and (.home_id | type) == "string" and .task_id == $task)
      and (.instructions | type == "object" and exact_keys(["path","sha256"])
        and (.path | type) == "string" and (.sha256 | type) == "string"
        and (.sha256 | test("^[0-9a-f]{64}$")))
      and (.identity | type == "object" and exact_keys(["schema","status","sha256"])
        and .schema == $contract
        and ((.status == "linked" and (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
          or (.status == "unlinked" and .sha256 == null)))
      and (.replacement | type) == "boolean"
      and ((.replacement == true
            and (.previous_transaction_id | type) == "string"
            and (.previous_transaction_id | test("^[A-Za-z0-9._:-]{1,128}$"))
            and (.previous_instructions_sha256 | type) == "string"
            and (.previous_instructions_sha256 | test("^[0-9a-f]{64}$")))
        or (.replacement == false and .previous_transaction_id == null
            and .previous_instructions_sha256 == null))
    ) | $wrapper
  ' "$DISPATCH_STATE" 2>/dev/null) || die "work identity dispatch state is malformed: $DISPATCH_STATE"
  printf '%s\n' "$wrapper" | cmp -s "$DISPATCH_STATE" - \
    || die "work identity dispatch state is not canonical: $DISPATCH_STATE"
  DISPATCH_STATUS=$(printf '%s' "$wrapper" | jq -r '.state')
  DISPATCH_TRANSACTION=$(printf '%s' "$wrapper" | jq -r '.transaction_id')
  DISPATCH_HOME=$(printf '%s' "$wrapper" | jq -r '.binding.home')
  DISPATCH_HOME_ID=$(printf '%s' "$wrapper" | jq -r '.binding.home_id')
  DISPATCH_INSTRUCTIONS=$(printf '%s' "$wrapper" | jq -r '.instructions.path')
  DISPATCH_INSTRUCTIONS_SHA=$(printf '%s' "$wrapper" | jq -r '.instructions.sha256')
  DISPATCH_IDENTITY_STATUS=$(printf '%s' "$wrapper" | jq -r '.identity.status')
  DISPATCH_IDENTITY_SHA=$(printf '%s' "$wrapper" | jq -r '.identity.sha256 // ""')
  DISPATCH_REPLACEMENT=$(printf '%s' "$wrapper" | jq -r '.replacement')
  DISPATCH_PREVIOUS_TRANSACTION=$(printf '%s' "$wrapper" | jq -r '.previous_transaction_id // ""')
  DISPATCH_PREVIOUS_SHA=$(printf '%s' "$wrapper" | jq -r '.previous_instructions_sha256 // ""')
  ensure_home_identity
  [ "$DISPATCH_HOME" = "$FM_HOME_REAL" ] && [ "$DISPATCH_HOME_ID" = "$FM_HOME_ID" ] \
    || die "work identity dispatch home binding is mismatched"
  dispatch_transaction_valid "$DISPATCH_TRANSACTION" \
    || die "work identity dispatch transaction is malformed"
  dispatch_instructions_path_valid "$DISPATCH_INSTRUCTIONS" \
    || die "work identity dispatch instructions path is unsafe"
}

write_dispatch_state() {  # <prepared|completed> <task> <transaction> <path> <brief-sha> <linked|unlinked> <identity-sha> <replacement> <previous-transaction> <previous-sha>
  local state=$1 task=$2 transaction=$3 path=$4 brief_sha=$5 identity_status=$6 identity_sha=$7 replacement=$8 previous_transaction=$9 previous_sha=${10} payload
  ensure_home_identity
  payload=$(jq -n -S -c \
    --arg schema "$DISPATCH_STATE_SCHEMA" --arg state "$state" --arg transaction "$transaction" \
    --arg home "$FM_HOME_REAL" --arg home_id "$FM_HOME_ID" --arg task "$task" \
    --arg path "$path" --arg brief_sha "$brief_sha" --arg contract "$SCHEMA" \
    --arg identity_status "$identity_status" --arg identity_sha "$identity_sha" \
    --argjson replacement "$replacement" --arg previous_transaction "$previous_transaction" \
    --arg previous_sha "$previous_sha" '
      {schema:$schema,state:$state,transaction_id:$transaction,
       binding:{home:$home,home_id:$home_id,task_id:$task},
       instructions:{path:$path,sha256:$brief_sha},
       identity:{schema:$contract,status:$identity_status,
         sha256:(if $identity_status == "linked" then $identity_sha else null end)},
       replacement:$replacement,
       previous_transaction_id:(if $replacement then $previous_transaction else null end),
       previous_instructions_sha256:(if $replacement then $previous_sha else null end)}') \
    || die "cannot build work identity dispatch state"
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-dispatch-state.XXXXXX") \
    || die "cannot create work identity dispatch state"
  printf '%s\n' "$payload" > "$TMP" || die "cannot write work identity dispatch state"
  chmod 600 "$TMP" || die "cannot protect work identity dispatch state"
  owned_atomic_replace "$TMP" "$DISPATCH_STATE" "work identity dispatch state"
  TMP=
}

validate_dispatch_prior_locked() {
  local current_hash
  if [ ! -e "$DISPATCH_PRIOR" ] && [ ! -L "$DISPATCH_PRIOR" ]; then return 0; fi
  [ "$DISPATCH_REPLACEMENT" = true ] \
    || die "non-replacement dispatch has retained prior instructions"
  IFS=$'\t' read -r DISPATCH_PRIOR_ENTRY_STATE DISPATCH_PRIOR_ENTRY_DIGEST \
    < <(owned_removal_expectation "$DISPATCH_PRIOR" "retained prior dispatch instructions") \
    || die "cannot bind validated retained prior dispatch instructions"
  safe_regular_file "$DISPATCH_PRIOR" "retained prior dispatch instructions"
  current_hash=$(sha256_file "$DISPATCH_PRIOR") \
    || die "SHA-256 is unavailable for retained prior instructions"
  [ "$current_hash" = "$DISPATCH_PREVIOUS_SHA" ] \
    || die "retained prior dispatch instructions are stale or mismatched"
}

retire_dispatch_prior_locked() {
  validate_dispatch_prior_locked
  if [ -e "$DISPATCH_PRIOR" ] || [ -L "$DISPATCH_PRIOR" ]; then
    owned_remove "$DISPATCH_PRIOR" "retained prior dispatch instructions" \
      "$DISPATCH_PRIOR_ENTRY_STATE" "$DISPATCH_PRIOR_ENTRY_DIGEST"
  fi
}

validate_completed_dispatch() {  # <task-id> [meta]
  local task=$1 meta=${2:-$STATE_REAL/$1.meta} projection meta_arg='' owned=0
  [ "$DISPATCH_STATUS" = completed ] || die "work identity dispatch is incomplete for task $task"
  validate_dispatch_prior_locked
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if [ "$META_CAPTURE_SOURCE" != "$meta" ]; then
      capture_metadata "$meta"
      owned=1
    fi
    validate_dispatch_metadata_receipt "$meta"
    meta_arg=$meta
  fi
  if [ -e "$DISPATCH_INSTRUCTIONS" ] || [ -L "$DISPATCH_INSTRUCTIONS" ]; then
    [ -n "$meta_arg" ] || die "completed dispatch metadata is absent for task $task"
    capture_identity_projection_locked "$task" "$DISPATCH_INSTRUCTIONS" \
      "$meta_arg" "$DISPATCH_INSTRUCTIONS"
    projection=$IDENTITY_PROJECTION
    [ "$BRIEF_HASH" = "$DISPATCH_INSTRUCTIONS_SHA" ] \
      || die "completed dispatch instructions digest is stale or mismatched"
    [ "$(printf '%s' "$projection" | jq -r '.status')" = "$DISPATCH_IDENTITY_STATUS" ] \
      || die "completed dispatch identity status is stale or mismatched"
    [ "$(printf '%s' "$projection" | jq -r '.sha256 // ""')" = "$DISPATCH_IDENTITY_SHA" ] \
      || die "completed dispatch identity digest is stale or mismatched"
  elif [ -e "$meta" ] || [ -L "$meta" ]; then
    die "completed dispatch instructions are absent for task $task"
  fi
  [ "$owned" -eq 0 ] || finish_metadata_capture "$meta"
}

reject_handoff_guard() {  # <task-id>
  local task=$1
  validate_unlinked_guard "$task"
  validate_unlinked_reservation "$task"
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source "$task"
    die "work identity ownership was handed off for task $task"
  fi
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target "$task"
    handoff_target_matches_current
    case "$HANDOFF_STATE" in
      completed) validate_committed_target "$task" ;;
      intake-completed) validate_relinked_target "$task" ;;
      *) die "work identity ownership handoff is incomplete for task $task" ;;
    esac
  fi
}

record_ownership_guard() {  # <task-id> [meta]
  local task=$1
  RECORD_HANDOFF_TRANSITION=0
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    ensure_home_identity
    read_unlinked_reservation "$task"
    die "task $task has an in-progress persistent secondmate reservation"
  fi
  if [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ]; then
    ensure_home_identity
    read_unlinked_guard "$task"
    die "task $task is permanently reserved as an unlinked persistent secondmate"
  fi
  RECORD_HANDOFF_TRANSFER=
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source "$task"
    die "work identity ownership was handed off for task $task"
  fi
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target "$task"
    handoff_target_matches_current
    case "$HANDOFF_STATE" in
      completed)
        validate_committed_target "$task"
        if [ "$HANDOFF_STATUS" = unlinked ]; then
          RECORD_HANDOFF_TRANSITION=1
          RECORD_HANDOFF_TRANSFER=$HANDOFF_TRANSFER
        fi
        ;;
      intake-prepared)
        [ "$HANDOFF_STATUS" = unlinked ] \
          || die "linked handoff target has an invalid intake transition"
        if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
          validate_relinked_target "$task"
        else
          validate_committed_target "$task"
        fi
        RECORD_HANDOFF_TRANSITION=1
        RECORD_HANDOFF_TRANSFER=$HANDOFF_TRANSFER
        ;;
      intake-completed) validate_relinked_target "$task" ;;
      *) die "work identity ownership handoff is incomplete for task $task" ;;
    esac
  fi
  reject_dispatch_guard "$@"
}

record_handoff_transition_prepare() {  # <task-id>
  local task=$1
  [ "$RECORD_HANDOFF_TRANSITION" -eq 1 ] || return 0
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$RECORD_HANDOFF_TRANSFER" ] \
    || die "work identity handoff changed during intake"
  case "$HANDOFF_STATE" in
    completed) write_handoff_state "$TARGET_HANDOFF" target intake-prepared "$HANDOFF_TRANSFER" ;;
    intake-prepared) ;;
    intake-completed) RECORD_HANDOFF_TRANSITION=0 ;;
    *) die "work identity ownership handoff is incomplete for task $task" ;;
  esac
}

record_handoff_transition_complete() {  # <task-id>
  local task=$1
  [ "$RECORD_HANDOFF_TRANSITION" -eq 1 ] || return 0
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$RECORD_HANDOFF_TRANSFER" ] \
    || die "work identity handoff changed during intake"
  [ "$HANDOFF_STATE" = intake-prepared ] \
    || die "work identity intake transition is not prepared for task $task"
  validate_relinked_target "$task"
  write_handoff_state "$TARGET_HANDOFF" target intake-completed "$HANDOFF_TRANSFER"
  RECORD_HANDOFF_TRANSITION=0
}

reject_dispatch_guard() {  # <task-id> [meta]
  local task=$1 meta=${2:-$STATE_REAL/$1.meta} rc=0 owned=0
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    [ "$DISPATCH_STATUS" = completed ] \
      || die "work identity dispatch is incomplete for task $task"
    validate_completed_dispatch "$task" "$meta"
    return 0
  fi
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  if [ "$META_CAPTURE_SOURCE" != "$meta" ]; then
    capture_metadata "$meta"
    owned=1
  fi
  meta_field_exact "$meta" work_identity_dispatch_transaction || rc=$?
  case "$rc" in
    0) die "task metadata dispatch transaction has no exact owner receipt: $meta" ;;
    1) ;;
    *) die "task metadata has duplicate work identity dispatch transactions: $meta" ;;
  esac
  [ "$owned" -eq 0 ] || finish_metadata_capture "$meta"
}

reject_ownership_guard() {  # <task-id> [meta]
  reject_handoff_guard "$1"
  reject_dispatch_guard "$@"
}

reject_dispatch_for_handoff() {  # <task-id>
  local task=$1 meta="$STATE_REAL/$1.meta"
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    ensure_home_identity
    read_unlinked_reservation "$task"
    die "persistent secondmate control task $task has an in-progress reservation"
  fi
  if [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ]; then
    ensure_home_identity
    read_unlinked_guard "$task"
    die "persistent secondmate control task $task cannot be handed off as backlog"
  fi
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    [ "$DISPATCH_STATUS" = completed ] \
      || die "task $task has an in-progress work identity dispatch"
  fi
  [ ! -e "$meta" ] && [ ! -L "$meta" ] \
    || die "task $task has dispatch metadata and cannot be handed off as backlog"
}

validate_source_transfer() {  # <task-id>; HANDOFF_* already loaded
  local task=$1 meta rebound rebound_hash
  ensure_home_identity
  [ "$HANDOFF_SOURCE_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_SOURCE_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff source binding does not match the active home"
  meta="$STATE_REAL/$task.meta"
  if [ "$HANDOFF_STATUS" = linked ]; then
    [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "linked handoff source record is absent"
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_SOURCE_SHA" ] || die "handoff source digest is stale or mismatched"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
    rebound=$(printf '%s' "$WORK_CANONICAL" | jq -S -c \
      --arg home "$HANDOFF_TARGET_HOME" --arg home_id "$HANDOFF_TARGET_HOME_ID" \
      '.binding.home = $home | .binding.home_id = $home_id') \
      || die "cannot rebind work identity for handoff"
    [ "$rebound" = "$HANDOFF_RECORD" ] || die "handoff target record no longer matches its source"
    rebound_hash=$(printf '%s\n' "$rebound" | sha256_stream) \
      || die "SHA-256 is unavailable for rebound work identity"
    [ "$rebound_hash" = "$HANDOFF_TARGET_SHA" ] || die "handoff target digest is mismatched"
  else
    [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] || die "unlinked handoff source gained a linked record"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
  fi
}

build_handoff_transfer() {  # <task-id> <target-home> <target-home-id> <backlog-sha256>; sets HANDOFF_CANONICAL
  local task=$1 target_home=$2 target_home_id=$3 backlog_sha=${4:-} meta status source_hash target_hash record material transfer_id
  ensure_home_identity
  meta="$STATE_REAL/$task.meta"
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
    status=linked
    source_hash=$WORK_HASH
    record=$(printf '%s' "$WORK_CANONICAL" | jq -S -c \
      --arg home "$target_home" --arg home_id "$target_home_id" \
      '.binding.home = $home | .binding.home_id = $home_id') \
      || die "cannot rebind work identity for handoff"
    canonicalize_manifest <(printf '%s\n' "$record") "$task" "$target_home" "$target_home_id" >/dev/null
    target_hash=$(printf '%s\n' "$record" | sha256_stream) \
      || die "SHA-256 is unavailable for handoff target record"
  else
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
    status=unlinked
    source_hash=
    target_hash=
    record=null
  fi
  material=$(jq -n -S -c \
    --arg schema "$HANDOFF_SCHEMA" --arg source_home "$FM_HOME_REAL" --arg source_home_id "$FM_HOME_ID" \
    --arg target_home "$target_home" --arg target_home_id "$target_home_id" --arg task "$task" \
    --arg status "$status" --arg source_hash "$source_hash" --arg target_hash "$target_hash" \
    --arg backlog_sha "$backlog_sha" --argjson record "$record" '
      {schema:$schema,
       source:{home:$source_home,home_id:$source_home_id,task_id:$task},
       target:{home:$target_home,home_id:$target_home_id,task_id:$task},
       backlog:{task_sha256:(if $backlog_sha == "" then null else $backlog_sha end)},
       identity:{status:$status,
         source_sha256:(if $status == "linked" then $source_hash else null end),
         target_sha256:(if $status == "linked" then $target_hash else null end),
         record:(if $status == "linked" then $record else null end)}}') \
    || die "cannot build work identity handoff transfer"
  transfer_id=$(printf '%s\n' "$material" | sha256_stream) \
    || die "SHA-256 is unavailable for work identity handoff"
  HANDOFF_CANONICAL=$(printf '%s' "$material" | jq -S -c --arg transfer_id "$transfer_id" '. + {transfer_id:$transfer_id}') \
    || die "cannot finalize work identity handoff transfer"
  validate_handoff_text "$HANDOFF_CANONICAL" "$task"
}

emit_handoff_prepare() {
  local mode=$1 created=$2 transfer=$3
  if [ "$mode" = result ]; then
    jq -n -S -c --argjson created "$created" --argjson transfer "$transfer" \
      '{created:$created,transfer:$transfer}'
  else
    printf '%s\n' "$transfer"
  fi
}

handoff_prepare() {  # <task-id> <target-home> <target-home-id> <backlog-sha256> [transfer|result]
  local task=$1 target_home=$2 target_home_id=$3 backlog_sha=${4:-} mode=${5:-transfer}
  if [ -n "$backlog_sha" ]; then
    case "$backlog_sha" in *[!0-9a-f]*) die "handoff backlog task digest is malformed" ;; esac
    [ "${#backlog_sha}" -eq 64 ] || die "handoff backlog task digest is malformed"
  fi
  validate_home_literal "$target_home"
  home_id_literal_valid "$target_home_id" || die "work identity handoff target home id is malformed"
  ensure_home_identity
  [ "$target_home" != "$FM_HOME_REAL" ] || [ "$target_home_id" != "$FM_HOME_ID" ] \
    || die "work identity handoff target matches the active home"
  identity_mutation_lock_acquire "$task"
  reject_dispatch_for_handoff "$task"
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target "$task"
    handoff_target_matches_current
    case "$HANDOFF_STATE" in
      completed) validate_committed_target "$task" ;;
      intake-completed) validate_relinked_target "$task" ;;
      *) die "task $task has an incomplete incoming work identity handoff" ;;
    esac
  fi
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source "$task"
    [ "$HANDOFF_TARGET_HOME" = "$target_home" ] && [ "$HANDOFF_TARGET_HOME_ID" = "$target_home_id" ] \
      || die "task $task is already prepared for a different handoff target"
    [ "$HANDOFF_BACKLOG_SHA" = "$backlog_sha" ] \
      || die "task $task is already prepared for different backlog content ($HANDOFF_BACKLOG_SHA != $backlog_sha)"
    validate_source_transfer "$task"
    emit_handoff_prepare "$mode" false "$HANDOFF_TRANSFER"
    return 0
  fi
  build_handoff_transfer "$task" "$target_home" "$target_home_id" "$backlog_sha"
  write_handoff_state "$SOURCE_HANDOFF" source prepared "$HANDOFF_CANONICAL"
  emit_handoff_prepare "$mode" true "$HANDOFF_CANONICAL"
}

handoff_target_matches_current() {
  ensure_home_identity
  [ "$HANDOFF_TARGET_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_TARGET_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff target binding does not match the active home"
}

handoff_stage() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested meta
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  reject_dispatch_for_handoff "$task"
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source "$task"
    die "handoff target task $task is already owned by an outgoing transfer"
  fi
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target "$task"
    [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task has a different prepared incoming handoff"
    [ "$HANDOFF_STATE" != intake-prepared ] \
      || die "task $task has an incomplete post-handoff intake"
    return 0
  fi
  validate_handoff_text "$requested" "$task"
  meta="$STATE_REAL/$task.meta"
  if [ "$HANDOFF_STATUS" = linked ]; then
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      die "handoff target already has an unowned linked record"
    elif [ -e "$BRIEF_DEFAULT" ] || [ -L "$BRIEF_DEFAULT" ] || [ -e "$meta" ] || [ -L "$meta" ]; then
      die "linked handoff identity must arrive before destination instructions and metadata"
    fi
  else
    [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] || die "unlinked handoff target already has a linked record"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
  fi
  write_handoff_state "$TARGET_HANDOFF" target prepared "$requested"
}

validate_committed_target() {  # <task-id>; HANDOFF_* loaded
  local task=$1 meta
  meta="$STATE_REAL/$task.meta"
  BRIEF_HASH=
  if [ "$HANDOFF_STATUS" = linked ]; then
    [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "committed handoff target linked record is absent"
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
      || die "committed handoff target linked record is conflicting"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
  else
    [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] || die "committed unlinked handoff target gained a linked record"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
  fi
}

validate_relinked_target() {  # <task-id>; HANDOFF_* loaded
  local task=$1 meta
  [ "$HANDOFF_STATUS" = unlinked ] \
    || die "linked handoff target has an invalid intake transition"
  meta="$STATE_REAL/$task.meta"
  [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] \
    || die "completed handoff intake record is absent"
  validate_sidecar "$SIDECAR" "$task"
  [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
    || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
  [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
}

publish_handoff_sidecar() {  # <task-id>; HANDOFF_RECORD/HANDOFF_TARGET_SHA loaded, lock held
  local task=$1
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
      || die "handoff target linked record is conflicting"
    return 0
  fi
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-handoff-sidecar.XXXXXX") \
    || die "cannot create handoff work identity record"
  printf '%s\n' "$HANDOFF_RECORD" > "$TMP" || die "cannot write handoff work identity record"
  validate_sidecar "$TMP" "$task"
  if ! publish_no_clobber "$TMP" "$SIDECAR" "handoff work identity record"; then
    [ -z "$TMP" ] || rm -f -- "$TMP"
    TMP=
    [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "cannot publish handoff work identity record"
  fi
  validate_sidecar "$SIDECAR" "$task"
  [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
    || die "published handoff work identity record is conflicting"
}

handoff_backlog_prepare() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  [ -n "$HANDOFF_BACKLOG_SHA" ] || die "task $task handoff has no exact backlog commitment"
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ] \
    || die "task $task has no prepared incoming handoff"
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  case "$HANDOFF_STATE" in
    prepared) write_handoff_state "$TARGET_HANDOFF" target backlog-prepared "$requested" ;;
    backlog-prepared|backlog-completed|completed) ;;
    *) die "task $task has an invalid backlog handoff state" ;;
  esac
}

handoff_backlog_complete() {  # <task-id> <transfer-path> <backlog-sha256>
  local task=$1 path=$2 observed_sha=$3 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  [ -n "$HANDOFF_BACKLOG_SHA" ] || die "task $task handoff has no exact backlog commitment"
  [ "$observed_sha" = "$HANDOFF_BACKLOG_SHA" ] \
    || die "task $task destination backlog content does not match its transfer"
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ] \
    || die "task $task has no prepared incoming handoff"
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  case "$HANDOFF_STATE" in
    prepared|backlog-prepared) write_handoff_state "$TARGET_HANDOFF" target backlog-completed "$requested" ;;
    backlog-completed|completed) ;;
    *) die "task $task destination backlog was not validated before receipt" ;;
  esac
}

handoff_commit() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ] \
    || die "task $task has no prepared incoming handoff"
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  if [ "$HANDOFF_STATE" = completed ]; then
    validate_committed_target "$task"
    return 0
  fi
  if [ "$HANDOFF_STATE" = intake-completed ]; then
    validate_relinked_target "$task"
    return 0
  fi
  [ "$HANDOFF_STATE" != intake-prepared ] \
    || die "task $task has an incomplete post-handoff intake"
  if [ -n "$HANDOFF_BACKLOG_SHA" ]; then
    [ "$HANDOFF_STATE" = backlog-completed ] \
      || die "task $task exact backlog receipt is incomplete"
  else
    [ "$HANDOFF_STATE" = prepared ] \
      || die "task $task has an invalid incoming handoff state"
  fi
  if [ "$HANDOFF_STATUS" = linked ]; then
    publish_handoff_sidecar "$task"
  fi
  validate_committed_target "$task"
  write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
}

handoff_abort() {  # <task-id> <transfer-path>; 4 means target is already committed
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$TARGET_HANDOFF" ] && [ ! -L "$TARGET_HANDOFF" ]; then
    return 0
  fi
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  if [ "$HANDOFF_STATE" = completed ]; then
    validate_committed_target "$task"
    return 4
  fi
  if [ "$HANDOFF_STATE" = intake-completed ]; then
    validate_relinked_target "$task"
    return 4
  fi
  [ "$HANDOFF_STATE" != intake-prepared ] \
    || die "task $task has an incomplete post-handoff intake"
  [ "$HANDOFF_STATE" != backlog-completed ] || return 4
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    [ "$HANDOFF_STATUS" = linked ] || die "unlinked handoff target gained a linked record"
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
      || die "committed handoff target linked record is conflicting"
    write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
    return 4
  fi
  owned_remove "$TARGET_HANDOFF" "handoff target state" \
    "$HANDOFF_STATE_ENTRY_STATE" "$HANDOFF_STATE_ENTRY_DIGEST"
}

handoff_backlog_state() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$TARGET_HANDOFF" ] && [ ! -L "$TARGET_HANDOFF" ]; then
    printf 'absent\n'
    return 0
  fi
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  case "$HANDOFF_STATE" in
    prepared|backlog-prepared|backlog-completed|completed) printf '%s\n' "$HANDOFF_STATE" ;;
    *) die "task $task has no valid exact backlog handoff state" ;;
  esac
}

handoff_target_state() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$TARGET_HANDOFF" ] && [ ! -L "$TARGET_HANDOFF" ]; then
    printf 'absent\n'
    return 0
  fi
  read_handoff_state "$TARGET_HANDOFF" target "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  if [ "$HANDOFF_STATE" = completed ]; then
    validate_committed_target "$task"
    printf 'completed\n'
    return 0
  fi
  if [ "$HANDOFF_STATE" = intake-completed ]; then
    validate_relinked_target "$task"
    printf 'completed\n'
    return 0
  fi
  [ "$HANDOFF_STATE" != intake-prepared ] \
    || die "task $task has an incomplete post-handoff intake"
  if [ "$HANDOFF_STATUS" = linked ] && { [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; }; then
    validate_committed_target "$task"
    write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
    printf 'completed\n'
    return 0
  fi
  printf 'prepared\n'
}

handoff_complete() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  ensure_home_identity
  [ "$HANDOFF_SOURCE_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_SOURCE_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff completion source does not match the active home"
  identity_mutation_lock_acquire "$task"
  [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ] || die "task $task has no prepared source handoff"
  read_handoff_state "$SOURCE_HANDOFF" source "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different source handoff"
  validate_source_transfer "$task"
  [ "$HANDOFF_STATE" = completed ] || write_handoff_state "$SOURCE_HANDOFF" source completed "$requested"
}

handoff_cancel() {  # <task-id> <transfer-path>; 4 means source is already completed
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  ensure_home_identity
  [ "$HANDOFF_SOURCE_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_SOURCE_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff cancellation source does not match the active home"
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$SOURCE_HANDOFF" ] && [ ! -L "$SOURCE_HANDOFF" ]; then return 0; fi
  read_handoff_state "$SOURCE_HANDOFF" source "$task"
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different source handoff"
  [ "$HANDOFF_STATE" != completed ] || return 4
  owned_remove "$SOURCE_HANDOFF" "handoff source state" \
    "$HANDOFF_STATE_ENTRY_STATE" "$HANDOFF_STATE_ENTRY_DIGEST"
}

render_identity_projection_locked() {  # <task-id> [brief] [meta] [meta-brief-path]
  local task=$1 brief=${2:-} meta=${3:-} meta_brief_path=${4:-} reason
  ensure_home_identity
  META_PROVENANCE=absent
  BRIEF_PROVENANCE=absent
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ -z "$brief" ] || validate_brief_binding "$brief" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ -z "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH" "$BRIEF_HASH" "$meta_brief_path"
    jq -n -S -c \
      --argjson record "$WORK_CANONICAL" \
      --arg schema "$SCHEMA" \
      --arg hash "$WORK_HASH" \
      --arg brief_provenance "$BRIEF_PROVENANCE" \
      --arg meta_provenance "$META_PROVENANCE" '
        {status:"linked",schema:$schema,sha256:$hash,
         provenance:{record:"intake-sidecar",instructions:$brief_provenance,metadata:$meta_provenance}}
        + ($record | del(.schema))'
    return 0
  fi
  [ -z "$brief" ] || validate_brief_binding "$brief" unlinked
  [ -z "$meta" ] || validate_meta_binding "$meta" unlinked "" "$BRIEF_HASH" "$meta_brief_path"
  if [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ]; then
    validate_unlinked_guard "$task"
    reason=explicitly-unlinked
  elif [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    validate_unlinked_reservation "$task"
    reason=explicitly-unlinked
  elif [ "$META_PROVENANCE" = metadata ] || [ "$BRIEF_PROVENANCE" = generated-instructions ]; then
    reason=explicitly-unlinked
  else
    reason=legacy-no-record
  fi
  jq -n -S -c \
    --arg schema "$SCHEMA" \
    --arg home "$FM_HOME_REAL" \
    --arg home_id "$FM_HOME_ID" \
    --arg task "$task" \
    --arg reason "$reason" \
    --arg brief_provenance "$BRIEF_PROVENANCE" \
    --arg meta_provenance "$META_PROVENANCE" '
      {status:"unlinked",schema:$schema,sha256:null,binding:{home:$home,home_id:$home_id,task_id:$task},
       initiative:null,plan_id:null,stage:null,work_units:[],sources:[],reason:$reason,
       provenance:{record:"absent",instructions:$brief_provenance,metadata:$meta_provenance}}'
}

capture_identity_projection_locked() {  # <task-id> [brief] [meta] [meta-brief-path]
  PROJECTION_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-projection.XXXXXX") \
    || die "cannot capture work identity projection"
  render_identity_projection_locked "$@" > "$PROJECTION_TMP"
  IDENTITY_PROJECTION=$(cat "$PROJECTION_TMP") || die "cannot read work identity projection"
  rm -f -- "$PROJECTION_TMP"
  PROJECTION_TMP=
}

project_identity() {  # <task-id> [brief] [meta]
  local task=$1 brief=${2:-} meta=${3:-} meta_brief_path='' recorded_brief='' rc=0 meta_captured=0
  identity_lock_acquire "$task"
  if [ -n "$meta" ]; then
    capture_metadata "$meta"
    meta_captured=1
  fi
  reject_ownership_guard "$task" "$meta"
  if [ -n "$meta" ]; then
    meta_field_exact "$meta" launch_brief || rc=$?
    case "$rc" in
      0)
        recorded_brief=$META_VALUE
        [ -z "$brief" ] || [ "$brief" = "$recorded_brief" ] \
          || die "explicit generated instructions do not match task metadata: $meta"
        brief=$recorded_brief
        meta_brief_path=$recorded_brief
        ;;
      1) ;;
      *) die "task metadata has duplicate launch brief paths: $meta" ;;
    esac
  fi
  if [ -z "$brief" ] && { [ -e "$BRIEF_DEFAULT" ] || [ -L "$BRIEF_DEFAULT" ]; }; then
    brief=$BRIEF_DEFAULT
  fi
  capture_identity_projection_locked "$task" "$brief" "$meta" "$meta_brief_path"
  [ "$meta_captured" -eq 0 ] || finish_metadata_capture "$meta"
  printf '%s\n' "$IDENTITY_PROJECTION"
}

validate_unlinked_applicability_locked() {  # <task-id>
  local task=$1 meta="$STATE_REAL/$1.meta"
  reject_handoff_guard "$task"
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    [ "$DISPATCH_IDENTITY_STATUS" = unlinked ] \
      || die "persistent secondmate control task $task cannot carry a linked work identity"
    if [ "$DISPATCH_STATUS" = completed ]; then
      validate_completed_dispatch "$task" "$meta"
    fi
  elif [ -e "$meta" ] || [ -L "$meta" ]; then
    capture_identity_projection_locked "$task" "" "$meta"
    [ "$(printf '%s' "$IDENTITY_PROJECTION" | jq -r '.status')" = unlinked ] \
      || die "persistent secondmate control task $task cannot carry a linked work identity"
  elif [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    die "persistent secondmate control task $task cannot carry a linked work identity"
  fi
}

emit_unlinked_projection_locked() {  # <task-id>
  local task=$1 meta="$STATE_REAL/$1.meta" projection
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    capture_identity_projection_locked "$task" "" "$meta"
  else
    capture_identity_projection_locked "$task"
  fi
  projection=$IDENTITY_PROJECTION
  [ "$(printf '%s' "$projection" | jq -r '.status')" = unlinked ] \
    || die "persistent secondmate control task $task cannot carry a linked work identity"
  printf '%s\n' "$projection"
}

reserve_unlinked() {  # <task-id> <reason>
  local task=$1 reason=$2
  [ "$reason" = persistent-secondmate ] || die "unsupported unlinked reservation reason"
  identity_mutation_lock_acquire "$task"
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    read_unlinked_reservation "$task"
    die "task $task has an in-progress persistent secondmate reservation"
  fi
  validate_unlinked_applicability_locked "$task"
  if [ ! -e "$UNLINKED_GUARD" ] && [ ! -L "$UNLINKED_GUARD" ]; then
    write_unlinked_guard "$task" "$reason"
  else
    read_unlinked_guard "$task"
  fi
  emit_unlinked_projection_locked "$task"
}

unlinked_prepare() {  # <task-id> <reason> <transaction>
  local task=$1 reason=$2 transaction=$3
  [ "$reason" = persistent-secondmate ] || die "unsupported unlinked reservation reason"
  dispatch_transaction_valid "$transaction" || die "unlinked reservation transaction is malformed"
  identity_mutation_lock_acquire "$task"
  validate_unlinked_applicability_locked "$task"
  if [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ]; then
    read_unlinked_guard "$task"
    if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
      read_unlinked_reservation "$task"
      [ "$UNLINKED_RESERVATION_TRANSACTION" = "$transaction" ] \
        || die "task $task prepared a different unlinked reservation"
      owned_remove "$UNLINKED_RESERVATION" "committed unlinked reservation" \
        "$UNLINKED_RESERVATION_ENTRY_STATE" "$UNLINKED_RESERVATION_ENTRY_DIGEST"
    fi
    emit_unlinked_projection_locked "$task"
    return 0
  fi
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    read_unlinked_reservation "$task"
    [ "$UNLINKED_RESERVATION_TRANSACTION" = "$transaction" ] \
      || die "task $task prepared a different unlinked reservation"
  else
    write_unlinked_reservation "$task" "$reason" "$transaction"
  fi
  emit_unlinked_projection_locked "$task"
}

unlinked_commit() {  # <task-id> <transaction>
  local task=$1 transaction=$2
  dispatch_transaction_valid "$transaction" || die "unlinked reservation transaction is malformed"
  identity_mutation_lock_acquire "$task"
  validate_unlinked_applicability_locked "$task"
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    read_unlinked_reservation "$task"
    [ "$UNLINKED_RESERVATION_TRANSACTION" = "$transaction" ] \
      || die "task $task prepared a different unlinked reservation"
  elif [ ! -e "$UNLINKED_GUARD" ] && [ ! -L "$UNLINKED_GUARD" ]; then
    die "task $task has no prepared unlinked reservation"
  fi
  if [ ! -e "$UNLINKED_GUARD" ] && [ ! -L "$UNLINKED_GUARD" ]; then
    write_unlinked_guard "$task" persistent-secondmate
  else
    read_unlinked_guard "$task"
  fi
  if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
    owned_remove "$UNLINKED_RESERVATION" "committed unlinked reservation" \
      "$UNLINKED_RESERVATION_ENTRY_STATE" "$UNLINKED_RESERVATION_ENTRY_DIGEST"
  fi
  emit_unlinked_projection_locked "$task"
}

unlinked_abort() {  # <task-id> <transaction>; 4 means committed
  local task=$1 transaction=$2
  dispatch_transaction_valid "$transaction" || die "unlinked reservation transaction is malformed"
  identity_mutation_lock_acquire "$task"
  if [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ]; then
    read_unlinked_guard "$task"
    if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
      read_unlinked_reservation "$task"
      [ "$UNLINKED_RESERVATION_TRANSACTION" = "$transaction" ] \
        || die "task $task prepared a different unlinked reservation"
      owned_remove "$UNLINKED_RESERVATION" "committed unlinked reservation" \
        "$UNLINKED_RESERVATION_ENTRY_STATE" "$UNLINKED_RESERVATION_ENTRY_DIGEST"
    fi
    return 4
  fi
  if [ ! -e "$UNLINKED_RESERVATION" ] && [ ! -L "$UNLINKED_RESERVATION" ]; then
    return 0
  fi
  read_unlinked_reservation "$task"
  [ "$UNLINKED_RESERVATION_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different unlinked reservation"
  owned_remove "$UNLINKED_RESERVATION" "unlinked reservation" \
    "$UNLINKED_RESERVATION_ENTRY_STATE" "$UNLINKED_RESERVATION_ENTRY_DIGEST"
}

brief_publish() {  # <task-id> <draft>
  local task=$1 draft=$2
  safe_regular_file "$draft" "generated instruction draft"
  identity_mutation_lock_acquire "$task"
  reject_ownership_guard "$task"
  [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
    || die "generated instructions already exist: $BRIEF_DEFAULT"
  RETAIN_BRIEF_CAPTURE=1
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    validate_brief_binding "$draft" linked "$WORK_HASH" "$WORK_CANONICAL"
  else
    validate_brief_binding "$draft" unlinked
  fi
  RETAIN_BRIEF_CAPTURE=0
  [ -n "$BRIEF_VALIDATED_CAPTURE" ] || die "cannot retain validated generated instructions"
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-brief.XXXXXX") \
    || die "cannot create generated instructions"
  cp -- "$BRIEF_VALIDATED_CAPTURE" "$TMP" || die "cannot capture generated instructions"
  rm -f -- "$BRIEF_VALIDATED_CAPTURE"
  BRIEF_VALIDATED_CAPTURE=
  chmod 600 "$TMP" || die "cannot protect generated instructions"
  if ! publish_no_clobber "$TMP" "$BRIEF_DEFAULT" "generated instructions"; then
    [ -z "$TMP" ] || rm -f -- "$TMP"
    TMP=
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || die "generated instructions already exist: $BRIEF_DEFAULT"
    die "cannot publish generated instructions: $BRIEF_DEFAULT"
  fi
}

dispatch_projection_matches_state() {  # <projection-json> <brief-sha>
  local projection=$1 brief_sha=$2
  [ "$brief_sha" = "$DISPATCH_INSTRUCTIONS_SHA" ] \
    || die "dispatch instructions digest is stale or mismatched"
  [ "$(printf '%s' "$projection" | jq -r '.status')" = "$DISPATCH_IDENTITY_STATUS" ] \
    || die "dispatch identity status is stale or mismatched"
  [ "$(printf '%s' "$projection" | jq -r '.sha256 // ""')" = "$DISPATCH_IDENTITY_SHA" ] \
    || die "dispatch identity digest is stale or mismatched"
}

capture_dispatch_draft_locked() {  # <task-id> <brief>
  RETAIN_BRIEF_CAPTURE=1
  capture_identity_projection_locked "$1" "$2"
  RETAIN_BRIEF_CAPTURE=0
  [ -n "$BRIEF_VALIDATED_CAPTURE" ] || die "cannot retain validated dispatch instructions"
}

publish_dispatch_instructions_locked() {  # <task-id>
  local task=$1 current_hash=
  if [ -e "$DISPATCH_INSTRUCTIONS" ] || [ -L "$DISPATCH_INSTRUCTIONS" ]; then
    safe_regular_file "$DISPATCH_INSTRUCTIONS" "dispatch instructions"
    current_hash=$(sha256_file "$DISPATCH_INSTRUCTIONS") \
      || die "SHA-256 is unavailable for dispatch instructions"
    if [ "$current_hash" = "$DISPATCH_INSTRUCTIONS_SHA" ]; then
      rm -f -- "$BRIEF_VALIDATED_CAPTURE"
      BRIEF_VALIDATED_CAPTURE=
      return 0
    fi
    [ "$DISPATCH_REPLACEMENT" = true ] && [ "$current_hash" = "$DISPATCH_PREVIOUS_SHA" ] \
      || die "dispatch instructions path contains stale or mismatched bytes"
  else
    [ "$DISPATCH_REPLACEMENT" = false ] \
      || die "replacement dispatch instructions are unexpectedly absent"
  fi
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-launch-brief.XXXXXX") \
    || die "cannot create authoritative dispatch instructions"
  cp -- "$BRIEF_VALIDATED_CAPTURE" "$TMP" \
    || die "cannot capture authoritative dispatch instructions"
  chmod 400 "$TMP" || die "cannot protect authoritative dispatch instructions"
  owned_atomic_replace "$TMP" "$DISPATCH_INSTRUCTIONS" "authoritative dispatch instructions"
  TMP=
  rm -f -- "$BRIEF_VALIDATED_CAPTURE"
  BRIEF_VALIDATED_CAPTURE=
}

dispatch_metadata_transaction_locked() {  # <meta>
  local meta=$1 rc=0 transaction
  capture_metadata "$meta"
  meta_field_exact "$meta" work_identity_dispatch_transaction || rc=$?
  [ "$rc" -eq 0 ] || {
    [ "$rc" -eq 1 ] \
      && die "task metadata has no work identity dispatch transaction: $meta"
    die "task metadata has duplicate work identity dispatch transactions: $meta"
  }
  transaction=$META_VALUE
  finish_metadata_capture "$meta"
  printf '%s\n' "$transaction"
}

validate_prior_dispatch_metadata_locked() {  # <task-id> <meta>
  local task=$1 meta=$2 rc=0 value
  capture_metadata "$meta"
  for value in \
    "work_identity_dispatch_transaction=$DISPATCH_PREVIOUS_TRANSACTION" \
    "launch_brief=$DISPATCH_INSTRUCTIONS" \
    "launch_brief_sha256=$DISPATCH_PREVIOUS_SHA" \
    "work_identity_schema=$SCHEMA" \
    "work_identity_status=$DISPATCH_IDENTITY_STATUS"
  do
    rc=0
    meta_field_exact "$meta" "${value%%=*}" || rc=$?
    [ "$rc" -eq 0 ] && [ "$META_VALUE" = "${value#*=}" ] \
      || die "prior dispatch metadata is stale or mismatched: $meta"
  done
  rc=0
  meta_field_exact "$meta" endpoint_task_id || rc=$?
  [ "$rc" -eq 0 ] && [ "$META_VALUE" = "$task" ] \
    || die "prior dispatch metadata task binding is stale or mismatched: $meta"
  rc=0
  meta_field_exact "$meta" work_identity_sha256 || rc=$?
  if [ "$DISPATCH_IDENTITY_STATUS" = linked ]; then
    [ "$rc" -eq 0 ] && [ "$META_VALUE" = "$DISPATCH_IDENTITY_SHA" ] \
      || die "prior dispatch metadata identity digest is stale or mismatched: $meta"
  else
    [ "$rc" -eq 1 ] \
      || die "prior unlinked dispatch metadata carries an identity digest: $meta"
  fi
  finish_metadata_capture "$meta"
}

emit_dispatch_binding() {  # <transaction> <projection>
  jq -n -S -c --arg transaction "$1" --arg hash "$DISPATCH_INSTRUCTIONS_SHA" \
    --argjson identity "$2" \
    '{transaction_id:$transaction,instructions_sha256:$hash,work_identity:$identity}'
}

dispatch_prepare() {  # <task-id> <brief-draft> <instructions-path> <transaction> [meta] [prior-brief] [resume]
  local task=$1 brief=$2 instructions_path=$3 transaction=$4 meta=${5:-} prior_brief=${6:-} resume=${7:-false}
  local projection previous_hash='' previous_transaction='' identity_status identity_sha
  local existing_status='' existing_path='' existing_sha='' recovery_meta recovery_transaction
  dispatch_transaction_valid "$transaction" || die "dispatch transaction is malformed"
  safe_regular_file "$brief" "dispatch instruction draft"
  dispatch_instructions_path_valid "$instructions_path" || die "dispatch instructions path is unsafe"
  identity_mutation_lock_acquire "$task"
  reject_handoff_guard "$task"
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    existing_status=$DISPATCH_STATUS
    existing_path=$DISPATCH_INSTRUCTIONS
    existing_sha=$DISPATCH_INSTRUCTIONS_SHA
    if [ "$existing_status" = prepared ]; then
      [ "$instructions_path" = "$DISPATCH_INSTRUCTIONS" ] \
        || die "task $task has a different in-progress work identity dispatch"
      capture_dispatch_draft_locked "$task" "$brief"
      projection=$IDENTITY_PROJECTION
      dispatch_projection_matches_state "$projection" "$BRIEF_HASH"
      recovery_meta="$STATE_REAL/$task.meta"
      if [ -e "$recovery_meta" ] || [ -L "$recovery_meta" ]; then
        recovery_transaction=$(dispatch_metadata_transaction_locked "$recovery_meta")
        if [ "$recovery_transaction" = "$DISPATCH_TRANSACTION" ]; then
          publish_dispatch_instructions_locked "$task"
          complete_prepared_dispatch_locked "$task" "$DISPATCH_INSTRUCTIONS" "$recovery_meta"
          emit_dispatch_binding "$DISPATCH_TRANSACTION" "$projection"
          return 0
        fi
        [ "$DISPATCH_REPLACEMENT" = true ] \
          && [ "$recovery_transaction" = "$DISPATCH_PREVIOUS_TRANSACTION" ] \
          || die "task $task has metadata for a different work identity dispatch"
        validate_prior_dispatch_metadata_locked "$task" "$recovery_meta"
      fi
      publish_dispatch_instructions_locked "$task"
      emit_dispatch_binding "$DISPATCH_TRANSACTION" "$projection"
      return 0
    fi
    validate_completed_dispatch "$task"
    retire_dispatch_prior_locked
    if [ "$resume" = true ] && [ -z "$meta" ] && [ -z "$prior_brief" ]; then
      capture_identity_projection_locked "$task" "$brief" "$STATE_REAL/$task.meta" "$instructions_path"
      projection=$IDENTITY_PROJECTION
      dispatch_projection_matches_state "$projection" "$BRIEF_HASH"
      emit_dispatch_binding "$DISPATCH_TRANSACTION" "$projection"
      return 0
    fi
    previous_transaction=$DISPATCH_TRANSACTION
  fi
  if [ -n "$meta" ] || [ -n "$prior_brief" ]; then
    [ -n "$meta" ] && [ -n "$prior_brief" ] \
      || die "replacement dispatch requires prior metadata and instructions"
    [ -e "$meta" ] || [ -L "$meta" ] || die "replacement dispatch metadata is absent: $meta"
    [ -e "$prior_brief" ] || [ -L "$prior_brief" ] || die "replacement dispatch instructions are absent: $prior_brief"
    RETAIN_BRIEF_CAPTURE=1
    capture_identity_projection_locked "$task" "$prior_brief" "$meta" "$instructions_path"
    RETAIN_BRIEF_CAPTURE=0
    [ -n "$BRIEF_VALIDATED_CAPTURE" ] || die "cannot retain prior dispatch instructions"
    projection=$IDENTITY_PROJECTION
    previous_hash=$BRIEF_HASH
    if [ "$existing_status" = completed ]; then
      [ "$existing_path" = "$instructions_path" ] && [ "$existing_sha" = "$previous_hash" ] \
        || die "replacement dispatch does not match the completed instruction binding"
    fi
    [ ! -e "$DISPATCH_PRIOR" ] && [ ! -L "$DISPATCH_PRIOR" ] \
      || die "replacement dispatch already has retained prior instructions"
    DISPATCH_PRIOR_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-dispatch-prior.XXXXXX") \
      || die "cannot retain prior dispatch instructions"
    cp -- "$BRIEF_VALIDATED_CAPTURE" "$DISPATCH_PRIOR_TMP" \
      || die "cannot retain prior dispatch instructions"
    rm -f -- "$BRIEF_VALIDATED_CAPTURE" || die "cannot retire captured prior dispatch instructions"
    BRIEF_VALIDATED_CAPTURE=
    chmod 400 "$DISPATCH_PRIOR_TMP" || die "cannot protect retained prior dispatch instructions"
    owned_atomic_replace "$DISPATCH_PRIOR_TMP" "$DISPATCH_PRIOR" "retained prior dispatch instructions"
    DISPATCH_PRIOR_TMP=
    DISPATCH_PRIOR_CLEANUP=1
  else
    [ -z "$existing_status" ] \
      || die "task $task was already dispatched; replacement requires prior metadata and instructions"
    [ ! -e "$STATE_REAL/$task.meta" ] && [ ! -L "$STATE_REAL/$task.meta" ] \
      || die "fresh dispatch found existing task metadata"
    [ ! -e "$instructions_path" ] && [ ! -L "$instructions_path" ] \
      || die "fresh dispatch found existing launch instructions"
  fi
  capture_dispatch_draft_locked "$task" "$brief"
  projection=$IDENTITY_PROJECTION
  identity_status=$(printf '%s' "$projection" | jq -er '.status') \
    || die "dispatch identity status is malformed"
  identity_sha=$(printf '%s' "$projection" | jq -r '.sha256 // ""')
  write_dispatch_state prepared "$task" "$transaction" "$instructions_path" "$BRIEF_HASH" \
    "$identity_status" "$identity_sha" "$([ -n "$previous_hash" ] && printf true || printf false)" \
    "$previous_transaction" "$previous_hash"
  DISPATCH_PRIOR_CLEANUP=0
  read_dispatch_state "$task"
  publish_dispatch_instructions_locked "$task"
  emit_dispatch_binding "$transaction" "$projection"
}

validate_dispatch_metadata_receipt() {  # <meta>
  local meta=$1 rc=0 owned=0
  if [ "$META_CAPTURE_SOURCE" != "$meta" ]; then
    capture_metadata "$meta"
    owned=1
  fi
  meta_field_exact "$meta" work_identity_dispatch_transaction || rc=$?
  [ "$rc" -eq 0 ] || {
    [ "$rc" -eq 1 ] \
      && die "task metadata has no work identity dispatch transaction: $meta"
    die "task metadata has duplicate work identity dispatch transactions: $meta"
  }
  [ "$META_VALUE" = "$DISPATCH_TRANSACTION" ] \
    || die "task metadata work identity dispatch transaction is stale or mismatched: $meta"
  [ "$owned" -eq 0 ] || finish_metadata_capture "$meta"
}

validate_dispatch_commit_candidate_locked() {  # <task-id> <brief> <meta>
  local task=$1 brief=$2 meta=$3 projection owned=0
  [ "$brief" = "$DISPATCH_INSTRUCTIONS" ] \
    || die "dispatch commit instructions path is mismatched"
  if [ "$META_CAPTURE_SOURCE" != "$meta" ]; then
    capture_metadata "$meta"
    owned=1
  fi
  validate_dispatch_metadata_receipt "$meta"
  capture_identity_projection_locked "$task" "$brief" "$meta" "$brief"
  projection=$IDENTITY_PROJECTION
  dispatch_projection_matches_state "$projection" "$BRIEF_HASH"
  [ "$owned" -eq 0 ] || finish_metadata_capture "$meta"
}

complete_prepared_dispatch_locked() {  # <task-id> <brief> <meta>
  local task=$1 brief=$2 meta=$3
  [ "$DISPATCH_STATUS" = prepared ] || die "task $task has no prepared work identity dispatch"
  validate_dispatch_commit_candidate_locked "$task" "$brief" "$meta"
  retire_dispatch_prior_locked
  write_dispatch_state completed "$task" "$DISPATCH_TRANSACTION" "$DISPATCH_INSTRUCTIONS" \
    "$DISPATCH_INSTRUCTIONS_SHA" "$DISPATCH_IDENTITY_STATUS" "$DISPATCH_IDENTITY_SHA" \
    "$DISPATCH_REPLACEMENT" "$DISPATCH_PREVIOUS_TRANSACTION" "$DISPATCH_PREVIOUS_SHA"
}

dispatch_commit_preflight() {  # <task-id> <brief> <meta> <transaction>
  local task=$1 brief=$2 meta=$3 transaction=$4
  identity_lock_acquire "$task"
  reject_handoff_guard "$task"
  [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ] \
    || die "task $task has no prepared work identity dispatch"
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different work identity dispatch"
  validate_dispatch_commit_candidate_locked "$task" "$brief" "$meta"
}

dispatch_publish() {  # <task-id> <brief> <metadata-candidate> <transaction>
  local task=$1 brief=$2 candidate=$3 transaction=$4 target="$STATE_REAL/$1.meta"
  [ "$candidate" != "$target" ] || die "dispatch metadata candidate must not be authoritative metadata"
  identity_mutation_lock_acquire "$task"
  reject_handoff_guard "$task"
  [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ] \
    || die "task $task has no prepared work identity dispatch"
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different work identity dispatch"
  if [ -e "$target" ] || [ -L "$target" ]; then
    safe_regular_file "$target" "authoritative task metadata"
  fi
  capture_metadata "$candidate"
  validate_dispatch_commit_candidate_locked "$task" "$brief" "$candidate"
  TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-meta.XXXXXX") \
    || die "cannot create authoritative task metadata"
  cp -- "$META_CAPTURE_TMP" "$TMP" || die "cannot capture authoritative task metadata"
  chmod 600 "$TMP" || die "cannot protect authoritative task metadata"
  finish_metadata_capture "$candidate"
  owned_atomic_replace "$TMP" "$target" "authoritative task metadata"
  TMP=
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task dispatch changed during metadata publication"
  if [ "$DISPATCH_STATUS" = completed ]; then
    validate_dispatch_commit_candidate_locked "$task" "$brief" "$target"
    retire_dispatch_prior_locked
    return 0
  fi
  complete_prepared_dispatch_locked "$task" "$brief" "$target"
}

dispatch_commit() {  # <task-id> <brief> <meta> <transaction>
  local task=$1 brief=$2 meta=$3 transaction=$4
  identity_mutation_lock_acquire "$task"
  reject_handoff_guard "$task"
  [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ] \
    || die "task $task has no prepared work identity dispatch"
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different work identity dispatch"
  if [ "$DISPATCH_STATUS" = completed ]; then
    validate_dispatch_commit_candidate_locked "$task" "$brief" "$meta"
    retire_dispatch_prior_locked
    return 0
  fi
  complete_prepared_dispatch_locked "$task" "$brief" "$meta"
}

dispatch_abort() {  # <task-id> <transaction>; 4 means committed, 5 means published metadata requires reconciliation
  local task=$1 transaction=$2 meta="$STATE_REAL/$1.meta" recorded_hash='' rc=0 current_hash
  local removal_state removal_digest
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$DISPATCH_STATE" ] && [ ! -L "$DISPATCH_STATE" ]; then return 0; fi
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different work identity dispatch"
  [ "$DISPATCH_STATUS" != completed ] || return 4
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    capture_metadata "$meta"
    meta_field_exact "$meta" launch_brief_sha256 || rc=$?
    [ "$rc" -le 1 ] || die "task metadata has duplicate launch brief digest fields: $meta"
    if [ "$rc" -eq 0 ]; then recorded_hash=$META_VALUE; fi
    finish_metadata_capture "$meta"
    if [ "$recorded_hash" = "$DISPATCH_INSTRUCTIONS_SHA" ]; then return 5; fi
    [ "$DISPATCH_REPLACEMENT" = true ] || return 5
  fi
  if [ "$DISPATCH_REPLACEMENT" = true ]; then
    IFS=$'\t' read -r removal_state removal_digest \
      < <(owned_removal_expectation "$DISPATCH_PRIOR" "retained prior dispatch instructions") \
      || die "cannot bind validated retained prior dispatch instructions"
    safe_regular_file "$DISPATCH_PRIOR" "retained prior dispatch instructions"
    current_hash=$(sha256_file "$DISPATCH_PRIOR") || die "SHA-256 is unavailable for retained prior instructions"
    [ "$current_hash" = "$DISPATCH_PREVIOUS_SHA" ] \
      || die "retained prior dispatch instructions are stale or mismatched"
    TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-launch-restore.XXXXXX") \
      || die "cannot restore prior dispatch instructions"
    cp -- "$DISPATCH_PRIOR" "$TMP" || die "cannot restore prior dispatch instructions"
    chmod 400 "$TMP" || die "cannot protect restored dispatch instructions"
    owned_atomic_replace "$TMP" "$DISPATCH_INSTRUCTIONS" "restored dispatch instructions"
    TMP=
    owned_remove "$DISPATCH_PRIOR" "retained prior dispatch instructions" \
      "$removal_state" "$removal_digest"
  elif [ -e "$DISPATCH_INSTRUCTIONS" ] || [ -L "$DISPATCH_INSTRUCTIONS" ]; then
    IFS=$'\t' read -r removal_state removal_digest \
      < <(owned_removal_expectation "$DISPATCH_INSTRUCTIONS" "prepared dispatch instructions") \
      || die "cannot bind validated prepared dispatch instructions"
    safe_regular_file "$DISPATCH_INSTRUCTIONS" "prepared dispatch instructions"
    current_hash=$(sha256_file "$DISPATCH_INSTRUCTIONS") \
      || die "SHA-256 is unavailable for prepared dispatch instructions"
    [ "$current_hash" = "$DISPATCH_INSTRUCTIONS_SHA" ] \
      || die "prepared dispatch instructions changed before abort"
    owned_remove "$DISPATCH_INSTRUCTIONS" "prepared dispatch instructions" \
      "$removal_state" "$removal_digest"
  fi
  owned_remove "$DISPATCH_STATE" "work identity dispatch" \
    "$DISPATCH_STATE_ENTRY_STATE" "$DISPATCH_STATE_ENTRY_DIGEST"
}

metadata_publish_unlinked() {  # <task-id> <candidate>
  local task=$1 candidate=$2 target="$STATE_REAL/$1.meta" captured target_state target_digest
  identity_mutation_lock_acquire "$task"
  validate_unlinked_guard "$task"
  [ -e "$UNLINKED_GUARD" ] || [ -L "$UNLINKED_GUARD" ] \
    || die "task $task has no committed unlinked identity"
  capture_metadata "$candidate"
  validate_meta_binding_captured "$candidate" unlinked
  awk -F= '
    !/^[A-Za-z_][A-Za-z0-9_]*=/ { exit 1 }
    { key=$1; if (seen[key]++) exit 1 }
    END { if (NR == 0) exit 1 }
  ' "$META_CAPTURE_TMP" || die "unlinked task metadata is malformed or has duplicate fields: $candidate"
  meta_field_exact "$candidate" endpoint_task_id \
    && [ "$META_VALUE" = "$task" ] \
    || die "unlinked task metadata has a mismatched endpoint task id: $candidate"
  meta_field_exact "$candidate" kind \
    && [ "$META_VALUE" = secondmate ] \
    || die "unlinked task metadata is not for a secondmate: $candidate"
  meta_field_exact "$candidate" mode \
    && [ "$META_VALUE" = secondmate ] \
    || die "unlinked task metadata has a mismatched mode: $candidate"
  captured=$META_CAPTURE_TMP
  META_CAPTURE_TMP=
  META_CAPTURE_SOURCE=
  META_CAPTURE_PARENT=
  META_CAPTURE_PARENT_ID=
  META_CAPTURE_BASE=
  META_CAPTURE_ENTRY_STATE=
  META_CAPTURE_ENTRY_DIGEST=
  TMP=$captured
  chmod 600 "$captured" || die "cannot protect unlinked task metadata candidate"
  if [ -e "$target" ] || [ -L "$target" ]; then
    capture_metadata "$target"
    validate_meta_binding_captured "$target" unlinked
    target_state=$META_CAPTURE_ENTRY_STATE
    target_digest=$META_CAPTURE_ENTRY_DIGEST
    [ -n "$target_state" ] && [ -n "$target_digest" ] \
      || die "unlinked task metadata target is not owner-managed: $target"
    if cmp -s "$captured" "$META_CAPTURE_TMP"; then
      rm -f -- "$captured"
      TMP=
      finish_metadata_capture "$target"
      return 0
    fi
    finish_metadata_capture "$target"
    owned_atomic_replace_expected "$captured" "$target" "unlinked task metadata" \
      "$target_state" "$target_digest"
  else
    owned_atomic_replace "$captured" "$target" "unlinked task metadata"
  fi
  TMP=
  validate_meta_binding "$target" unlinked
}

validate_dispatch_retirement_locked() {  # <task-id>
  local task=$1 launch="$STATE_REAL/$1.launch-brief.md"
  reject_handoff_guard "$task"
  if [ ! -e "$DISPATCH_STATE" ] && [ ! -L "$DISPATCH_STATE" ]; then return 0; fi
  read_dispatch_state "$task"
  [ "$DISPATCH_STATUS" = completed ] || die "task $task has an incomplete work identity dispatch"
  [ "$DISPATCH_INSTRUCTIONS" = "$launch" ] \
    || die "task $task dispatch instructions path is mismatched"
  validate_completed_dispatch "$task"
}

dispatch_retire_preflight() {  # <task-id>
  local task=$1
  identity_lock_acquire "$task"
  validate_dispatch_retirement_locked "$task"
}

dispatch_teardown_restore_locked() {
  local receipt_name=${DISPATCH_STATE##*/}
  python3 "$FS_OWNER" teardown-restore "$TASK_DIR" "$TASK_DIR_ID" "$receipt_name" \
    || die "cannot restore work identity dispatch after interrupted teardown: $DISPATCH_STATE"
}

dispatch_teardown_quarantine_locked() {  # <validated-state> <validated-digest> <transaction> <state-dir> <state-id> <meta-name> <meta-state> <meta-digest> <launch-name> <launch-state> <launch-digest>
  local receipt_name=${DISPATCH_STATE##*/} details
  details=$(python3 "$FS_OWNER" teardown-quarantine \
    "$TASK_DIR" "$TASK_DIR_ID" "$receipt_name" "$@") \
    || return 1
  DISPATCH_TEARDOWN_QUARANTINE_STATE=${details%%$'\t'*}
  DISPATCH_TEARDOWN_QUARANTINE_DIGEST=${details#*$'\t'}
  [ "$DISPATCH_TEARDOWN_QUARANTINE_STATE" != "$details" ] \
    && [ -n "$DISPATCH_TEARDOWN_QUARANTINE_DIGEST" ]
}

dispatch_teardown_state_locked() {  # <transaction>
  local receipt_name=${DISPATCH_STATE##*/}
  python3 "$FS_OWNER" teardown-state "$TASK_DIR" "$TASK_DIR_ID" "$receipt_name" "$1"
}

dispatch_teardown_records_quarantine_locked() {  # <transaction>
  local receipt_name=${DISPATCH_STATE##*/}
  python3 "$FS_OWNER" teardown-records-quarantine \
    "$TASK_DIR" "$TASK_DIR_ID" "$receipt_name" "$1"
}

dispatch_teardown_complete_locked() {  # <transaction>
  local receipt_name=${DISPATCH_STATE##*/}
  python3 "$FS_OWNER" teardown-command-complete \
    "$TASK_DIR" "$TASK_DIR_ID" "$receipt_name" "$1" \
    || die "cannot record completed work identity dispatch teardown: $DISPATCH_STATE"
}

dispatch_teardown_finalize_locked() {
  local receipt_name=${DISPATCH_STATE##*/}
  python3 "$FS_OWNER" teardown-finalize "$TASK_DIR" "$TASK_DIR_ID" "$receipt_name" \
    || die "cannot finalize work identity dispatch teardown: $DISPATCH_STATE"
}

dispatch_retire_run() {  # <task-id> [task-id...] [--whole-home] -- <command> [args...]
  local task rc meta launch authorization authorizations='' whole_home=0 owner_pid=${BASHPID:-$$}
  local receipt_parent receipt_parent_id receipt_name quarantine_name receipt_state receipt_digest index rollback
  local metadata_state metadata_digest launch_state launch_digest
  local batch_token seen_tasks=" $1 " recovery_state any_completed=0 partial_completion=0
  local -a tasks=("$1") command_argv=() recovery_states=()
  local -a receipt_parents=() receipt_parent_ids=() receipt_names=()
  local -a quarantine_names=() receipt_states=() receipt_digests=() receipt_present=() quarantined=()
  local -a metadata_states=() metadata_digests=() launch_states=() launch_digests=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    if [ "$1" = --whole-home ]; then
      whole_home=1
    else
      fm_pr_task_id_valid "$1" || die "invalid task id"
      case "$seen_tasks" in
        *" $1 "*) die "duplicate dispatch retirement task id: $1" ;;
      esac
      tasks+=("$1")
      seen_tasks="$seen_tasks$1 "
    fi
    shift
  done
  [ "$#" -gt 1 ] && [ "$1" = -- ] || die "dispatch-retire-run requires -- and a command"
  shift
  command_argv=("$@")
  batch_token=$(
    {
      printf 'dispatch-retire-run-v2\0%s\0' "$whole_home"
      printf '%s\0' "${tasks[@]}"
      printf '%s\0' --
      printf '%s\0' "${command_argv[@]}"
    } | sha256_stream
  ) || die "SHA-256 is unavailable for dispatch retirement"
  publication_lock_acquire
  for task in "${tasks[@]}"; do
    identity_lock_acquire "$task"
    recovery_state=$(dispatch_teardown_state_locked "$batch_token") \
      || die "cannot inspect interrupted work identity dispatch teardown"
    recovery_states+=("$recovery_state")
    case "$recovery_state" in
      command-completed|finalizing) any_completed=1 ;;
      absent|quarantined|legacy-quarantined) ;;
      *) die "work identity dispatch teardown state is malformed" ;;
    esac
    identity_lock_release
  done
  if [ "$any_completed" -eq 1 ]; then
    for index in "${!tasks[@]}"; do
      task=${tasks[$index]}
      case "${recovery_states[$index]}" in
        command-completed|finalizing)
          identity_lock_acquire "$task"
          dispatch_teardown_finalize_locked
          identity_lock_release
          ;;
        quarantined|legacy-quarantined)
          identity_lock_acquire "$task"
          dispatch_teardown_restore_locked
          identity_lock_release
          partial_completion=1
          ;;
        absent) ;;
        *) die "interrupted dispatch retirement has a malformed transaction state" ;;
      esac
    done
    [ "$partial_completion" -eq 0 ] || return 1
    return 0
  fi
  for index in "${!tasks[@]}"; do
    [ "${recovery_states[$index]}" != absent ] || continue
    task=${tasks[$index]}
    identity_lock_acquire "$task"
    dispatch_teardown_restore_locked
    identity_lock_release
  done
  for task in "${tasks[@]}"; do
    identity_lock_acquire "$task"
    receipt_name=work-identity-dispatch.json
    quarantine_name=.$receipt_name.teardown-quarantine
    DISPATCH_STATE_ENTRY_STATE=
    DISPATCH_STATE_ENTRY_DIGEST=
    validate_dispatch_retirement_locked "$task"
    metadata_state=
    metadata_digest=
    launch_state=
    launch_digest=
    if [ -n "$DISPATCH_STATE_ENTRY_STATE" ]; then
      IFS=$'\t' read -r metadata_state metadata_digest \
        < <(owned_removal_expectation "$STATE_REAL/$task.meta" "task dispatch metadata") \
        || die "cannot bind task dispatch metadata retirement"
      IFS=$'\t' read -r launch_state launch_digest \
        < <(owned_removal_expectation "$STATE_REAL/$task.launch-brief.md" "task dispatch instructions") \
        || die "cannot bind task dispatch instructions retirement"
    fi
    receipt_parent=$TASK_DIR
    receipt_parent_id=$TASK_DIR_ID
    receipt_state=${DISPATCH_STATE_ENTRY_STATE:-absent}
    receipt_digest=${DISPATCH_STATE_ENTRY_DIGEST:--}
    receipt_parents+=("$receipt_parent")
    receipt_parent_ids+=("$receipt_parent_id")
    receipt_names+=("$receipt_name")
    quarantine_names+=("$quarantine_name")
    receipt_states+=("$receipt_state")
    receipt_digests+=("$receipt_digest")
    metadata_states+=("$metadata_state")
    metadata_digests+=("$metadata_digest")
    launch_states+=("$launch_state")
    launch_digests+=("$launch_digest")
    if [ "$receipt_state" = absent ]; then
      receipt_present+=(0)
    else
      receipt_present+=(1)
    fi
    identity_lock_release
  done
  for index in "${!tasks[@]}"; do
    [ "${receipt_present[$index]}" = 1 ] || continue
    task=${tasks[$index]}
    identity_lock_acquire "$task"
    if ! dispatch_teardown_quarantine_locked \
      "${receipt_states[$index]}" "${receipt_digests[$index]}" "$batch_token" \
      "$STATE_REAL" "$STATE_DIR_ID" "$task.meta" \
      "${metadata_states[$index]}" "${metadata_digests[$index]}" \
      "$task.launch-brief.md" "${launch_states[$index]}" "${launch_digests[$index]}"; then
      identity_lock_release
      for rollback in "${quarantined[@]}" "$index"; do
        task=${tasks[$rollback]}
        identity_lock_acquire "$task"
        dispatch_teardown_restore_locked
        identity_lock_release
      done
      die "cannot quarantine complete work identity dispatch set for teardown"
    fi
    receipt_state=$DISPATCH_TEARDOWN_QUARANTINE_STATE
    receipt_digest=$DISPATCH_TEARDOWN_QUARANTINE_DIGEST
    receipt_states[index]=$receipt_state
    receipt_digests[index]=$receipt_digest
    quarantined+=("$index")
    identity_lock_release
  done
  for index in "${!tasks[@]}"; do
    [ "${receipt_present[$index]}" = 1 ] || continue
    task=${tasks[$index]}
    identity_lock_acquire "$task"
    if ! dispatch_teardown_records_quarantine_locked "$batch_token"; then
      identity_lock_release
      for rollback in "${quarantined[@]}"; do
        task=${tasks[$rollback]}
        identity_lock_acquire "$task"
        dispatch_teardown_restore_locked
        identity_lock_release
      done
      die "cannot quarantine complete work identity dispatch record set for teardown"
    fi
    identity_lock_release
  done
  for index in "${!tasks[@]}"; do
    [ "${receipt_present[$index]}" = 1 ] || continue
    task=${tasks[$index]}
    if [ "${metadata_states[$index]}" != absent ]; then
      IFS=$'\t' read -r metadata_state metadata_digest \
        < <(owned_removal_expectation \
          "$STATE_REAL/.$task.meta.teardown-quarantine" "task dispatch metadata quarantine") \
        || die "cannot bind quarantined task dispatch metadata"
      metadata_states[index]=$metadata_state
      metadata_digests[index]=$metadata_digest
    fi
    if [ "${launch_states[$index]}" != absent ]; then
      IFS=$'\t' read -r launch_state launch_digest \
        < <(owned_removal_expectation \
          "$STATE_REAL/.$task.launch-brief.md.teardown-quarantine" "task dispatch instructions quarantine") \
        || die "cannot bind quarantined task dispatch instructions"
      launch_states[index]=$launch_state
      launch_digests[index]=$launch_digest
    fi
    authorization=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$STATE_REAL" "$STATE_DIR_ID" "$task" \
      "$ACTIVE_PUBLICATION_LOCK_PARENT" "$ACTIVE_PUBLICATION_LOCK_PARENT_ID" \
      "$ACTIVE_PUBLICATION_LOCK" "$owner_pid" "$ACTIVE_PUBLICATION_LOCK_TOKEN" \
      "${receipt_parents[$index]}" "${receipt_parent_ids[$index]}" \
      "${receipt_names[$index]}" "${quarantine_names[$index]}" \
      "${receipt_states[$index]}" "${receipt_digests[$index]}" "$batch_token" \
      "$task.meta" "${metadata_states[$index]}" "${metadata_digests[$index]}" \
      "$task.launch-brief.md" "${launch_states[$index]}" "${launch_digests[$index]}")
    if [ -n "$authorizations" ]; then
      authorizations="$authorizations"$'\n'"$authorization"
    else
      authorizations=$authorization
    fi
  done
  if [ -n "${FM_TEARDOWN_DISPATCH_AUTHORIZATIONS:-}" ]; then
    authorizations="${FM_TEARDOWN_DISPATCH_AUTHORIZATIONS}"$'\n'"$authorizations"
  fi
  set +e
  FM_TEARDOWN_DISPATCH_AUTHORIZATIONS=$authorizations "${command_argv[@]}"
  rc=$?
  set -e
  if [ "$whole_home" -eq 1 ] \
     && [ ! -e "$FM_HOME_REAL" ] && [ ! -L "$FM_HOME_REAL" ]; then
    return "$rc"
  fi
  for index in "${!tasks[@]}"; do
    [ "${receipt_present[$index]}" = 1 ] || continue
    task=${tasks[$index]}
    identity_lock_acquire "$task"
    recovery_state=$(dispatch_teardown_state_locked "$batch_token") \
      || die "cannot inspect completed work identity dispatch teardown"
    if [ "$rc" -eq 0 ] && [ "$recovery_state" = quarantined ]; then
      python3 "$FS_OWNER" snapshot \
        "${receipt_parents[$index]}" "${receipt_parent_ids[$index]}" \
        "${quarantine_names[$index]}" "${receipt_states[$index]}" \
        "${receipt_digests[$index]}" >/dev/null \
        || die "task $task dispatch quarantine changed during teardown"
      dispatch_teardown_complete_locked "$batch_token"
      recovery_state=command-completed
    fi
    case "$recovery_state" in
      command-completed|finalizing|quarantined) ;;
      *) die "completed dispatch retirement has a malformed transaction state" ;;
    esac
    recovery_states[index]=$recovery_state
    identity_lock_release
  done
  if [ "$rc" -ne 0 ]; then
    for index in "${!tasks[@]}"; do
      [ "${receipt_present[$index]}" = 1 ] || continue
      task=${tasks[$index]}
      identity_lock_acquire "$task"
      case "${recovery_states[$index]}" in
        command-completed|finalizing) dispatch_teardown_finalize_locked ;;
        quarantined) dispatch_teardown_restore_locked ;;
        *) die "failed dispatch retirement has a malformed transaction state" ;;
      esac
      identity_lock_release
    done
    return "$rc"
  fi
  for index in "${!tasks[@]}"; do
    [ "${receipt_present[$index]}" = 1 ] || continue
    [ "${recovery_states[$index]}" = quarantined ] || continue
    task=${tasks[$index]}
    identity_lock_acquire "$task"
    dispatch_teardown_complete_locked "$batch_token"
    recovery_states[index]=command-completed
    identity_lock_release
  done
  for index in "${!tasks[@]}"; do
    [ "${receipt_present[$index]}" = 1 ] || continue
    task=${tasks[$index]}
    identity_lock_acquire "$task"
    python3 "$FS_OWNER" snapshot \
      "${receipt_parents[$index]}" "${receipt_parent_ids[$index]}" \
      "${quarantine_names[$index]}" "${receipt_states[$index]}" \
      "${receipt_digests[$index]}" >/dev/null \
      || die "task $task dispatch quarantine changed during teardown"
    dispatch_teardown_finalize_locked
    identity_lock_release
  done
  return "$rc"
}

dispatch_retire() {  # <task-id>
  local task=$1 meta="$STATE_REAL/$1.meta" launch="$STATE_REAL/$1.launch-brief.md"
  publication_lock_acquire
  identity_lock_acquire "$task"
  reject_handoff_guard "$task"
  if [ ! -e "$DISPATCH_STATE" ] && [ ! -L "$DISPATCH_STATE" ]; then return 0; fi
  read_dispatch_state "$task"
  [ "$DISPATCH_STATUS" = completed ] || die "task $task has an incomplete work identity dispatch"
  [ ! -e "$meta" ] && [ ! -L "$meta" ] \
    || die "task $task still has dispatch metadata"
  [ ! -e "$launch" ] && [ ! -L "$launch" ] \
    || die "task $task still has launch instructions"
  [ "$DISPATCH_INSTRUCTIONS" = "$launch" ] \
    || die "task $task dispatch instructions path is mismatched"
  retire_dispatch_prior_locked
  owned_remove "$DISPATCH_STATE" "work identity dispatch" \
    "$DISPATCH_STATE_ENTRY_STATE" "$DISPATCH_STATE_ENTRY_DIGEST"
}

publication_preflight_locked() {
  local task_dir task guarded guarded_path name
  ensure_data_dir
  ensure_state_dir
  ensure_home_identity
  for guarded_path in \
    "$STATE_REAL"/.*.meta.replace-journal \
    "$STATE_REAL"/.*.launch-brief.md.replace-journal
  do
    [ -e "$guarded_path" ] || [ -L "$guarded_path" ] || continue
    name=$(basename -- "$guarded_path")
    case "$name" in
      .*.meta.replace-journal) task=${name#.}; task=${task%.meta.replace-journal} ;;
      .*.launch-brief.md.replace-journal) task=${name#.}; task=${task%.launch-brief.md.replace-journal} ;;
      *) die "work identity publication journal is malformed: $guarded_path" ;;
    esac
    fm_pr_task_id_valid "$task" || die "work identity publication journal has an invalid task id: $guarded_path"
    identity_lock_acquire "$task"
    identity_lock_release
  done
  for task_dir in "$DATA_REAL"/*; do
    [ -e "$task_dir" ] || [ -L "$task_dir" ] || continue
    guarded=0
    for guarded_path in \
      "$task_dir/work-identity-handoff-source.json" \
      "$task_dir/work-identity-handoff-target.json" \
      "$task_dir/work-identity-dispatch.json" \
      "$task_dir/work-identity-unlinked-guard.json" \
      "$task_dir/work-identity-unlinked-reservation.json" \
      "$task_dir/.work-identity-handoff-source.json.replace-journal" \
      "$task_dir/.work-identity-handoff-target.json.replace-journal" \
      "$task_dir/.work-identity-dispatch.json.replace-journal" \
      "$task_dir/.work-identity-dispatch-prior.md.replace-journal" \
      "$task_dir/.work-identity-handoff-source.json.remove-journal" \
      "$task_dir/.work-identity-handoff-target.json.remove-journal" \
      "$task_dir/.work-identity-dispatch.json.remove-journal" \
      "$task_dir/.work-identity-dispatch-prior.md.remove-journal" \
      "$task_dir/.work-identity-unlinked-reservation.json.remove-journal"
    do
      if [ -e "$guarded_path" ] || [ -L "$guarded_path" ]; then guarded=1; fi
    done
    [ "$guarded" -eq 1 ] || continue
    task=$(basename "$task_dir")
    fm_pr_task_id_valid "$task" || die "work identity ownership guard has an invalid task id: $task"
    locate_task_dir "$task"
    identity_lock_acquire "$task"
    validate_unlinked_guard "$task"
    validate_unlinked_reservation "$task"
    if [ -e "$UNLINKED_RESERVATION" ] || [ -L "$UNLINKED_RESERVATION" ]; then
      die "task $task has an incomplete persistent secondmate reservation"
    fi
    if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
      read_handoff_state "$SOURCE_HANDOFF" source "$task"
      [ "$HANDOFF_STATE" = completed ] \
        || die "work identity ownership handoff is incomplete for task $task"
      validate_source_transfer "$task"
    fi
    if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
      read_handoff_state "$TARGET_HANDOFF" target "$task"
      handoff_target_matches_current
      case "$HANDOFF_STATE" in
        completed) validate_committed_target "$task" ;;
        intake-completed) validate_relinked_target "$task" ;;
        *) die "work identity ownership handoff is incomplete for task $task" ;;
      esac
    fi
    if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
      read_dispatch_state "$task"
      if [ "$DISPATCH_STATUS" = prepared ]; then
        complete_prepared_dispatch_locked "$task" "$DISPATCH_INSTRUCTIONS" "$STATE_REAL/$task.meta"
      else
        validate_completed_dispatch "$task"
      fi
    fi
    identity_lock_release
  done
}

publication_run() {
  local rc
  [ "$#" -gt 1 ] && [ "$1" = -- ] || die "publication-run requires -- and a command"
  shift
  DIE_STATUS=42
  publication_lock_acquire
  publication_preflight_locked
  set +e
  "$@"
  rc=$?
  set -e
  return "$rc"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
  home-id|limits|record-max-bytes|validate-index|validate-projections|publication-run) ;;
  template|record|verify|brief-block|brief-publish|project|dispatch-binding|dispatch-prepare|dispatch-commit-preflight|dispatch-publish|dispatch-commit|dispatch-abort|dispatch-retire-preflight|dispatch-retire-run|dispatch-retire|metadata-publish-unlinked|reserve-unlinked|unlinked-prepare|unlinked-commit|unlinked-abort|handoff-prepare|handoff-stage|handoff-backlog-prepare|handoff-backlog-complete|handoff-backlog-state|handoff-commit|handoff-abort|handoff-target-state|handoff-complete|handoff-cancel) ;;
  *) usage >&2; exit 2 ;;
esac
shift

case "$COMMAND" in
  publication-run)
    publication_run "$@"
    exit $?
    ;;
  home-id)
    [ "$#" -eq 0 ] || die "home-id accepts no arguments"
    ensure_home_identity
    printf '%s\n' "$FM_HOME_ID"
    exit 0
    ;;
  limits)
    [ "$#" -eq 0 ] || die "limits accepts no arguments"
    jq -n -c --argjson record "$MAX_BYTES" --argjson projection "$MAX_PROJECTION_BYTES" \
      '{record_max_bytes:$record,projection_max_bytes:$projection}'
    exit 0
    ;;
  record-max-bytes)
    [ "$#" -eq 0 ] || die "record-max-bytes accepts no arguments"
    printf '%s\n' "$MAX_BYTES"
    exit 0
    ;;
  validate-index)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || die "validate-index usage: fm-work-identity.sh validate-index --file <index.json|->"
    DIE_STATUS=42
    capture_contract_input "$2" "work identity projection index" "$MAX_PROJECTION_BATCH_BYTES"
    validate_projection_index "$CONTRACT_INPUT"
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    exit 0
    ;;
  validate-projections)
    EXPECTED_HOME=
    EXPECTED_HOME_ID=
    INPUT_PATH=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --home) shift; [ "$#" -gt 0 ] || die "--home requires a path"; EXPECTED_HOME=$1 ;;
        --home-id) shift; [ "$#" -gt 0 ] || die "--home-id requires an id"; EXPECTED_HOME_ID=$1 ;;
        --file) shift; [ "$#" -gt 0 ] || die "--file requires a path"; INPUT_PATH=$1 ;;
        *) die "unknown validate-projections argument: $1" ;;
      esac
      shift
    done
    [ -n "$EXPECTED_HOME" ] && [ -n "$EXPECTED_HOME_ID" ] && [ -n "$INPUT_PATH" ] \
      || die "validate-projections requires --home, --home-id, and --file"
    DIE_STATUS=42
    capture_contract_input "$INPUT_PATH" "work identity projection set" "$MAX_PROJECTION_BATCH_BYTES"
    validate_projection_set "$CONTRACT_INPUT" "$EXPECTED_HOME" "$EXPECTED_HOME_ID"
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    exit 0
    ;;
esac

TASK=${1:-}
[ -n "$TASK" ] || die "$COMMAND requires a task id"
shift
case "$COMMAND" in
  template|record) fm_task_id_creation_valid "$TASK" || die "invalid task id" ;;
  *) fm_pr_task_id_valid "$TASK" || die "invalid task id" ;;
esac

case "$COMMAND" in
  template)
    [ "$#" -eq 0 ] || die "template accepts only a task id"
    ensure_home_identity
    jq -n -S \
      --arg schema "$SCHEMA" --arg home "$FM_HOME_REAL" --arg home_id "$FM_HOME_ID" --arg task "$TASK" '
      {schema:$schema,binding:{home:$home,home_id:$home_id,task_id:$task},
       initiative:{namespace:"work-aligner",kind:"project",id:"replace-project-id",label:"Replace project label"},
       plan_id:{namespace:"work-aligner",kind:"plan",id:"replace-plan-id",label:"Replace plan label"},
       stage:{namespace:"work-aligner",kind:"stage",id:"replace-stage-id",label:"Replace stage label"},
       work_units:[{namespace:"work-aligner",kind:"work-unit",id:"replace-work-unit-id",label:"Replace work-unit label"}],
       sources:[{namespace:"dtm",kind:"issue",id:"replace-dtm-issue-id",label:"Replace DTM issue label"}]}'
    ;;
  record)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || die "record usage: fm-work-identity.sh record <task-id> --file <manifest.json>"
    MANIFEST=$2
    capture_manifest "$MANIFEST"
    CANONICAL=$(canonicalize_manifest "$MANIFEST_CAPTURE_TMP" "$TASK")
    identity_mutation_lock_acquire "$TASK"
    record_ownership_guard "$TASK"
    verify_manifest_capture
    rm -f -- "$MANIFEST_CAPTURE_TMP"
    MANIFEST_CAPTURE_TMP=
    MANIFEST_CAPTURE_SOURCE=
    META="$STATE_REAL/$TASK.meta"
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      validate_sidecar "$SIDECAR" "$TASK"
      if [ "$WORK_CANONICAL" = "$CANONICAL" ]; then
        [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
          || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
        [ ! -e "$META" ] && [ ! -L "$META" ] \
          || validate_meta_binding "$META" linked "$WORK_HASH"
        record_handoff_transition_complete "$TASK"
        printf 'recorded %s task=%s sha256=%s (unchanged)\n' "$SCHEMA" "$TASK" "$WORK_HASH"
        exit 0
      fi
      die "work identity is immutable once recorded; changed relation requires a new task id"
    elif [ -e "$BRIEF_DEFAULT" ] || [ -L "$BRIEF_DEFAULT" ] || [ -e "$META" ] || [ -L "$META" ]; then
      die "work identity must be recorded before generated instructions and dispatch"
    fi
    record_handoff_transition_prepare "$TASK"
    TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-record.XXXXXX") || die "cannot create work identity temporary file"
    printf '%s\n' "$CANONICAL" > "$TMP" || die "cannot write work identity temporary file"
    validate_sidecar "$TMP" "$TASK"
    if publish_no_clobber "$TMP" "$SIDECAR" "work identity record"; then
      validate_sidecar "$SIDECAR" "$TASK"
      record_handoff_transition_complete "$TASK"
      printf 'recorded %s task=%s sha256=%s\n' "$SCHEMA" "$TASK" "$WORK_HASH"
    else
      [ -z "$TMP" ] || rm -f -- "$TMP"
      TMP=
      [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "cannot publish work identity record"
      validate_sidecar "$SIDECAR" "$TASK"
      [ "$WORK_CANONICAL" = "$CANONICAL" ] \
        || die "work identity is immutable once recorded; changed relation requires a new task id"
      record_handoff_transition_complete "$TASK"
      printf 'recorded %s task=%s sha256=%s (unchanged)\n' "$SCHEMA" "$TASK" "$WORK_HASH"
    fi
    ;;
  brief-publish)
    [ "$#" -eq 2 ] && [ "$1" = --file ] \
      || die "brief-publish usage: fm-work-identity.sh brief-publish <task-id> --file <draft.md>"
    brief_publish "$TASK" "$2"
    ;;
  dispatch-prepare)
    DISPATCH_BRIEF=
    DISPATCH_INSTRUCTIONS_PATH=
    DISPATCH_TRANSACTION_ARG=
    DISPATCH_META=
    DISPATCH_PRIOR_BRIEF=
    DISPATCH_RESUME=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --brief) shift; [ "$#" -gt 0 ] || die "--brief requires a path"; DISPATCH_BRIEF=$1 ;;
        --instructions-path) shift; [ "$#" -gt 0 ] || die "--instructions-path requires a path"; DISPATCH_INSTRUCTIONS_PATH=$1 ;;
        --transaction) shift; [ "$#" -gt 0 ] || die "--transaction requires an id"; DISPATCH_TRANSACTION_ARG=$1 ;;
        --meta) shift; [ "$#" -gt 0 ] || die "--meta requires a path"; DISPATCH_META=$1 ;;
        --prior-brief) shift; [ "$#" -gt 0 ] || die "--prior-brief requires a path"; DISPATCH_PRIOR_BRIEF=$1 ;;
        --resume) DISPATCH_RESUME=true ;;
        *) die "unknown dispatch-prepare argument: $1" ;;
      esac
      shift
    done
    [ -n "$DISPATCH_BRIEF" ] && [ -n "$DISPATCH_INSTRUCTIONS_PATH" ] && [ -n "$DISPATCH_TRANSACTION_ARG" ] \
      || die "dispatch-prepare requires --brief, --instructions-path, and --transaction"
    dispatch_prepare "$TASK" "$DISPATCH_BRIEF" "$DISPATCH_INSTRUCTIONS_PATH" \
      "$DISPATCH_TRANSACTION_ARG" "$DISPATCH_META" "$DISPATCH_PRIOR_BRIEF" "$DISPATCH_RESUME"
    ;;
  dispatch-commit-preflight|dispatch-publish|dispatch-commit)
    DISPATCH_BRIEF=
    DISPATCH_META=
    DISPATCH_TRANSACTION_ARG=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --brief) shift; [ "$#" -gt 0 ] || die "--brief requires a path"; DISPATCH_BRIEF=$1 ;;
        --meta) shift; [ "$#" -gt 0 ] || die "--meta requires a path"; DISPATCH_META=$1 ;;
        --transaction) shift; [ "$#" -gt 0 ] || die "--transaction requires an id"; DISPATCH_TRANSACTION_ARG=$1 ;;
        *) die "unknown $COMMAND argument: $1" ;;
      esac
      shift
    done
    [ -n "$DISPATCH_BRIEF" ] && [ -n "$DISPATCH_META" ] && [ -n "$DISPATCH_TRANSACTION_ARG" ] \
      || die "$COMMAND requires --brief, --meta, and --transaction"
    case "$COMMAND" in
      dispatch-commit-preflight)
        dispatch_commit_preflight "$TASK" "$DISPATCH_BRIEF" "$DISPATCH_META" "$DISPATCH_TRANSACTION_ARG"
        ;;
      dispatch-publish)
        dispatch_publish "$TASK" "$DISPATCH_BRIEF" "$DISPATCH_META" "$DISPATCH_TRANSACTION_ARG"
        ;;
      dispatch-commit)
        dispatch_commit "$TASK" "$DISPATCH_BRIEF" "$DISPATCH_META" "$DISPATCH_TRANSACTION_ARG"
        ;;
    esac
    ;;
  dispatch-abort)
    [ "$#" -eq 2 ] && [ "$1" = --transaction ] \
      || die "dispatch-abort usage: fm-work-identity.sh dispatch-abort <task-id> --transaction <id>"
    dispatch_abort "$TASK" "$2"
    ;;
  dispatch-retire-preflight)
    [ "$#" -eq 0 ] || die "dispatch-retire-preflight accepts only a task id"
    dispatch_retire_preflight "$TASK"
    ;;
  dispatch-retire-run)
    dispatch_retire_run "$TASK" "$@"
    ;;
  dispatch-retire)
    [ "$#" -eq 0 ] || die "dispatch-retire accepts only a task id"
    dispatch_retire "$TASK"
    ;;
  metadata-publish-unlinked)
    [ "$#" -eq 2 ] && [ "$1" = --file ] \
      || die "metadata-publish-unlinked usage: fm-work-identity.sh metadata-publish-unlinked <task-id> --file <meta>"
    metadata_publish_unlinked "$TASK" "$2"
    ;;
  reserve-unlinked)
    [ "$#" -eq 2 ] && [ "$1" = --reason ] \
      || die "reserve-unlinked usage: fm-work-identity.sh reserve-unlinked <task-id> --reason persistent-secondmate"
    reserve_unlinked "$TASK" "$2"
    ;;
  unlinked-prepare)
    [ "$#" -eq 4 ] && [ "$1" = --reason ] && [ "$3" = --transaction ] \
      || die "unlinked-prepare usage: fm-work-identity.sh unlinked-prepare <task-id> --reason persistent-secondmate --transaction <id>"
    unlinked_prepare "$TASK" "$2" "$4"
    ;;
  unlinked-commit|unlinked-abort)
    [ "$#" -eq 2 ] && [ "$1" = --transaction ] \
      || die "$COMMAND usage: fm-work-identity.sh $COMMAND <task-id> --transaction <id>"
    case "$COMMAND" in
      unlinked-commit) unlinked_commit "$TASK" "$2" ;;
      unlinked-abort) unlinked_abort "$TASK" "$2" ;;
    esac
    ;;
  handoff-prepare)
    HANDOFF_TARGET_HOME_ARG=
    HANDOFF_TARGET_HOME_ID_ARG=
    HANDOFF_BACKLOG_SHA_ARG=
    HANDOFF_PREPARE_MODE=transfer
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --to-home) shift; [ "$#" -gt 0 ] || die "--to-home requires a path"; HANDOFF_TARGET_HOME_ARG=$1 ;;
        --to-home-id) shift; [ "$#" -gt 0 ] || die "--to-home-id requires an id"; HANDOFF_TARGET_HOME_ID_ARG=$1 ;;
        --backlog-sha256) shift; [ "$#" -gt 0 ] || die "--backlog-sha256 requires a digest"; HANDOFF_BACKLOG_SHA_ARG=$1 ;;
        --result) HANDOFF_PREPARE_MODE=result ;;
        *) die "unknown handoff-prepare argument: $1" ;;
      esac
      shift
    done
    [ -n "$HANDOFF_TARGET_HOME_ARG" ] && [ -n "$HANDOFF_TARGET_HOME_ID_ARG" ] \
      || die "handoff-prepare requires --to-home and --to-home-id"
    handoff_prepare "$TASK" "$HANDOFF_TARGET_HOME_ARG" "$HANDOFF_TARGET_HOME_ID_ARG" \
      "$HANDOFF_BACKLOG_SHA_ARG" "$HANDOFF_PREPARE_MODE"
    ;;
  handoff-stage|handoff-backlog-prepare|handoff-backlog-state|handoff-commit|handoff-abort|handoff-target-state|handoff-complete|handoff-cancel)
    [ "$#" -eq 2 ] && [ "$1" = --file ] \
      || die "$COMMAND usage: fm-work-identity.sh $COMMAND <task-id> --file <transfer.json|->"
    capture_contract_input "$2" "work identity handoff transfer" "$HANDOFF_MAX_BYTES"
    case "$COMMAND" in
      handoff-stage) handoff_stage "$TASK" "$CONTRACT_INPUT" ;;
      handoff-backlog-prepare) handoff_backlog_prepare "$TASK" "$CONTRACT_INPUT" ;;
      handoff-backlog-state) handoff_backlog_state "$TASK" "$CONTRACT_INPUT" ;;
      handoff-commit) handoff_commit "$TASK" "$CONTRACT_INPUT" ;;
      handoff-abort) handoff_abort "$TASK" "$CONTRACT_INPUT" ;;
      handoff-target-state) handoff_target_state "$TASK" "$CONTRACT_INPUT" ;;
      handoff-complete) handoff_complete "$TASK" "$CONTRACT_INPUT" ;;
      handoff-cancel) handoff_cancel "$TASK" "$CONTRACT_INPUT" ;;
    esac
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    CONTRACT_INPUT_TMP=
    ;;
  handoff-backlog-complete)
    [ "$#" -eq 4 ] && [ "$1" = --file ] && [ "$3" = --backlog-sha256 ] \
      || die "handoff-backlog-complete usage: fm-work-identity.sh handoff-backlog-complete <task-id> --file <transfer.json|-> --backlog-sha256 <digest>"
    capture_contract_input "$2" "work identity handoff transfer" "$HANDOFF_MAX_BYTES"
    handoff_backlog_complete "$TASK" "$CONTRACT_INPUT" "$4"
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    CONTRACT_INPUT_TMP=
    ;;
  verify)
    [ "$#" -eq 0 ] || die "verify accepts only a task id"
    locate_task_dir "$TASK"
    META="$STATE_REAL/$TASK.meta"
    [ -e "$META" ] || [ -L "$META" ] || META=
    project_identity "$TASK" "" "$META"
    ;;
  brief-block)
    [ "$#" -eq 0 ] || die "brief-block accepts only a task id"
    identity_lock_acquire "$TASK"
    reject_ownership_guard "$TASK"
    ensure_home_identity
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      validate_sidecar "$SIDECAR" "$TASK"
      cat <<EOF
# Exact work identity
Work identity contract: $SCHEMA sha256=$WORK_HASH
The namespace, kind, and id tuples below are exact identities; labels are display-only.
Work identity payload: $WORK_CANONICAL
Do not infer or replace these identities from the task title, repository, branch, worker, timing, endpoint, or status prose.
EOF
    else
      cat <<EOF
# Exact work identity
Work identity contract: $SCHEMA unlinked
No exact project, plan, stage, work-unit, or source identity was recorded at intake.
Do not infer one from the task title, repository, branch, worker, timing, endpoint, label, or status prose.
EOF
    fi
    ;;
  project|dispatch-binding)
    BRIEF=
    META=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --brief)
          shift; [ "$#" -gt 0 ] || die "--brief requires a path"
          BRIEF=$1
          ;;
        --meta)
          shift; [ "$#" -gt 0 ] || die "--meta requires a path"
          META=$1
          ;;
        *) die "unknown $COMMAND argument: $1" ;;
      esac
      shift
    done
    if [ "$COMMAND" = project ]; then
      project_identity "$TASK" "$BRIEF" "$META"
    else
      [ -n "$BRIEF" ] || die "dispatch-binding requires --brief"
      TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-dispatch.XXXXXX") \
        || die "cannot create dispatch binding projection"
      project_identity "$TASK" "$BRIEF" "$META" > "$TMP"
      [ -n "$BRIEF_HASH" ] || die "dispatch instructions have no validated digest"
      jq -n -S -c --arg hash "$BRIEF_HASH" --slurpfile identity "$TMP" \
        '{instructions_sha256:$hash,work_identity:$identity[0]}'
      rm -f -- "$TMP"
      TMP=
    fi
    ;;
esac
