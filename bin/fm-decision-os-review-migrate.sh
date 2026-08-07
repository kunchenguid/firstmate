#!/usr/bin/env bash
# Inventory and, only with --apply, migrate Decision OS review evidence stranded
# in Treehouse pool copies into the canonical shared review store.
#
# Usage:
#   fm-decision-os-review-migrate.sh <canonical-project>
#   fm-decision-os-review-migrate.sh --apply <canonical-project>
#
# The default is a non-mutating preflight. The project argument is the sole path
# authority: Treehouse inventory is queried from that checkout, every pool path
# must share its git common directory, and data/local/reviews must already expose
# the Decision OS contract as an in-project symlink to an existing directory.
#
# Apply defers every in-use or process-bearing slot. For an available slot it
# inventories each top-level run, copies an absent destination through a private
# hash-keyed staging area, verifies exact paths/types/bytes and SHA-256 hashes,
# syncs and re-verifies, then removes only the verified source entry. Existing
# identical destinations resume safely; non-identical collisions are never
# overwritten. A drained source directory is replaced by the same canonical
# link. Interrupted staging copies are private duplicates and are safely rebuilt
# on rerun; sources remain authoritative until final verification succeeds.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

APPLY=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --apply) APPLY=1; shift ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }

PROJECT=$1
for tool in git jq treehouse find sort cmp cp mv rm sync; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required command not found: $tool" >&2
    exit 1
  }
done

if command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
  sha256_stream() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
  sha256_stream() { shasum -a 256 | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  sha256_file() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }
  sha256_stream() { openssl dgst -sha256 | awk '{print $NF}'; }
else
  echo "error: sha256sum, shasum, or openssl is required" >&2
  exit 1
fi

resolved_dir() {
  [ -d "$1" ] || return 1
  cd "$1" 2>/dev/null && pwd -P
}

path_is_strict_child() {
  case "$2" in
    "$1"/*) [ "$1" != "$2" ] ;;
    *) return 1 ;;
  esac
}

git_common_dir_real() {
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) resolved_dir "$common" ;;
    *) resolved_dir "$repo/$common" ;;
  esac
}

reject_unsafe_text() {
  case "$1" in
    *$'\n'*|*$'\t'*) return 1 ;;
  esac
  return 0
}

inventory_path() {  # <root-entry> <manifest-file>
  local root=$1 manifest=$2 raw path rel target size hash
  raw="$manifest.raw"
  : > "$raw"
  if [ -L "$root" ]; then
    target=$(readlink "$root")
    reject_unsafe_text "$target" || return 1
    hash=$(printf '%s' "$target" | sha256_stream)
    printf 'L\t.\t%s\t%s\n' "$hash" "$target" >> "$raw"
  elif [ -f "$root" ]; then
    size=$(wc -c < "$root" | tr -d '[:space:]')
    hash=$(sha256_file "$root")
    printf 'F\t.\t%s\t%s\n' "$size" "$hash" >> "$raw"
  elif [ -d "$root" ]; then
    printf 'D\t.\n' >> "$raw"
    while IFS= read -r -d '' path; do
      rel=${path#"$root"/}
      reject_unsafe_text "$rel" || return 1
      if [ -L "$path" ]; then
        target=$(readlink "$path")
        reject_unsafe_text "$target" || return 1
        hash=$(printf '%s' "$target" | sha256_stream)
        printf 'L\t%s\t%s\t%s\n' "$rel" "$hash" "$target" >> "$raw"
      elif [ -f "$path" ]; then
        size=$(wc -c < "$path" | tr -d '[:space:]')
        hash=$(sha256_file "$path")
        printf 'F\t%s\t%s\t%s\n' "$rel" "$size" "$hash" >> "$raw"
      elif [ -d "$path" ]; then
        printf 'D\t%s\n' "$rel" >> "$raw"
      else
        echo "error: unsupported filesystem entry in review evidence: $path" >&2
        return 1
      fi
    done < <(find "$root" -mindepth 1 -print0)
  else
    echo "error: review evidence entry is neither file, directory, nor symlink: $root" >&2
    return 1
  fi
  LC_ALL=C sort "$raw" > "$manifest"
  rm -f "$raw"
}

PROJECT_REAL=$(resolved_dir "$PROJECT") || {
  echo "error: canonical project is missing or not a directory: $PROJECT" >&2
  exit 1
}
PROJECT_TOP=$(git -C "$PROJECT_REAL" rev-parse --show-toplevel 2>/dev/null || true)
PROJECT_TOP_REAL=$(resolved_dir "$PROJECT_TOP" 2>/dev/null || true)
if [ -z "$PROJECT_TOP_REAL" ] || [ "$PROJECT_TOP_REAL" != "$PROJECT_REAL" ]; then
  echo "error: canonical project must be a git checkout root: $PROJECT" >&2
  exit 1
fi
PROJECT_COMMON=$(git_common_dir_real "$PROJECT_REAL") || {
  echo "error: canonical project identity cannot be resolved: $PROJECT_REAL" >&2
  exit 1
}

CANONICAL_LINK="$PROJECT_REAL/data/local/reviews"
if [ ! -L "$CANONICAL_LINK" ] || [ ! -d "$CANONICAL_LINK" ]; then
  echo "error: canonical Decision OS review store must be an existing directory symlink: $CANONICAL_LINK" >&2
  exit 1
fi
CANONICAL_TARGET=$(resolved_dir "$CANONICAL_LINK") || {
  echo "error: canonical Decision OS review store cannot be resolved: $CANONICAL_LINK" >&2
  exit 1
}
if ! path_is_strict_child "$PROJECT_REAL" "$CANONICAL_TARGET"; then
  echo "error: canonical Decision OS review store resolves outside the project: $CANONICAL_TARGET" >&2
  exit 1
fi

TMP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-dos-review-migrate.XXXXXX")
cleanup() { rm -rf "$TMP_WORK"; }
trap cleanup EXIT INT TERM

POOL_JSON="$TMP_WORK/pool.json"
( cd "$PROJECT_REAL" && treehouse status --json ) > "$POOL_JSON" || {
  echo "error: treehouse pool inventory failed for $PROJECT_REAL" >&2
  exit 1
}
jq -e 'type == "array" and all(.[]; (.name|type)=="string" and (.path|type)=="string" and (.status|type)=="string" and (.processes|type)=="array")' "$POOL_JSON" >/dev/null || {
  echo "error: treehouse status returned an invalid pool inventory" >&2
  exit 1
}
if [ "$(jq '[.[].name] | length' "$POOL_JSON")" != "$(jq '[.[].name] | unique | length' "$POOL_JSON")" ] \
  || [ "$(jq '[.[].path] | length' "$POOL_JSON")" != "$(jq '[.[].path] | unique | length' "$POOL_JSON")" ]; then
  echo "error: treehouse pool inventory is ambiguous (duplicate name or path)" >&2
  exit 1
fi

recheck_index=0
slot_still_available() {  # <slot> <inventory-path>; 0=safe, 1=active/changed, 2=unconfirmed
  local slot_name=$1 inventory_path=$2 recheck
  recheck_index=$((recheck_index + 1))
  recheck="$TMP_WORK/recheck.$recheck_index.json"
  ( cd "$PROJECT_REAL" && treehouse status --json ) > "$recheck" || return 2
  jq -e 'type == "array" and all(.[]; (.name|type)=="string" and (.path|type)=="string" and (.status|type)=="string" and (.processes|type)=="array")' \
    "$recheck" >/dev/null || return 2
  if jq -e --arg name "$slot_name" --arg path "$inventory_path" \
    '[.[] | select(.name == $name)] as $matches
     | ($matches | length) == 1
       and $matches[0].path == $path
       and $matches[0].status == "available"
       and ($matches[0].processes | length) == 0' \
    "$recheck" >/dev/null; then
    return 0
  fi
  return 1
}

STAGE_ROOT="$PROJECT_REAL/data/local/.dos-3ndcm-review-migration"
refused=0
slot_index=0
while IFS=$'\t' read -r slot path status process_count; do
  slot_index=$((slot_index + 1))
  if ! reject_unsafe_text "$slot" || ! reject_unsafe_text "$path"; then
    echo "REFUSE unsafe treehouse inventory text at row=$slot_index" >&2
    refused=1
    continue
  fi
  case "$slot" in
    ''|*[!A-Za-z0-9._-]*)
      echo "REFUSE unsafe slot name '$slot'" >&2
      refused=1
      continue
      ;;
  esac
  slot_real=$(resolved_dir "$path" 2>/dev/null || true)
  if [ -z "$slot_real" ]; then
    echo "REFUSE slot=$slot missing or non-directory path=$path" >&2
    refused=1
    continue
  fi
  slot_top=$(git -C "$slot_real" rev-parse --show-toplevel 2>/dev/null || true)
  slot_top_real=$(resolved_dir "$slot_top" 2>/dev/null || true)
  slot_common=$(git_common_dir_real "$slot_real" 2>/dev/null || true)
  if [ "$slot_top_real" != "$slot_real" ] || [ -z "$slot_common" ] || [ "$slot_common" != "$PROJECT_COMMON" ]; then
    echo "REFUSE slot=$slot wrong project path=$slot_real" >&2
    refused=1
    continue
  fi

  slot_available=1
  if [ "$status" != available ] || [ "$process_count" -ne 0 ]; then
    slot_available=0
  fi

  reviews="$slot_real/data/local/reviews"
  if [ -L "$reviews" ]; then
    reviews_target=$(resolved_dir "$reviews" 2>/dev/null || true)
    if [ "$reviews_target" = "$CANONICAL_TARGET" ]; then
      echo "ALREADY-LINKED slot=$slot path=$reviews"
    else
      echo "REFUSE slot=$slot noncanonical review link path=$reviews target=${reviews_target:-missing}" >&2
      refused=1
    fi
    continue
  fi
  if [ -e "$reviews" ] && [ ! -d "$reviews" ]; then
    echo "REFUSE slot=$slot review source is not a directory path=$reviews" >&2
    refused=1
    continue
  fi
  if [ ! -e "$reviews" ]; then
    echo "EMPTY slot=$slot path=$reviews"
    if [ "$APPLY" -eq 1 ]; then
      if [ "$slot_available" -eq 0 ]; then
        echo "DEFER active slot=$slot path=$reviews status=$status processes=$process_count"
      elif mkdir -p "$(dirname "$reviews")" && ln -s "$CANONICAL_LINK" "$reviews"; then
        echo "LINKED slot=$slot target=$CANONICAL_LINK"
      else
        echo "REFUSE slot=$slot review link could not be created path=$reviews" >&2
        refused=1
      fi
    fi
    continue
  fi

  entries="$TMP_WORK/entries.$slot_index"
  : > "$entries"
  while IFS= read -r -d '' entry; do
    run=$(basename "$entry")
    reject_unsafe_text "$run" || {
      echo "REFUSE slot=$slot unsafe run id" >&2
      refused=1
      continue
    }
    printf '%s\n' "$run" >> "$entries"
  done < <(find "$reviews" -mindepth 1 -maxdepth 1 -print0)
  LC_ALL=C sort -o "$entries" "$entries"

  if [ ! -s "$entries" ]; then
    echo "EMPTY slot=$slot path=$reviews"
    if [ "$APPLY" -eq 1 ]; then
      if [ "$slot_available" -eq 0 ]; then
        echo "DEFER active slot=$slot path=$reviews status=$status processes=$process_count"
      elif rmdir "$reviews" && ln -s "$CANONICAL_LINK" "$reviews"; then
        echo "LINKED slot=$slot target=$CANONICAL_LINK"
      else
        echo "REFUSE slot=$slot empty review directory could not be replaced path=$reviews" >&2
        refused=1
      fi
    fi
    continue
  fi

  active=0
  slot_can_link=1
  if [ "$slot_available" -eq 0 ]; then
    active=1
    slot_can_link=0
  fi
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    source_entry="$reviews/$run"
    source_manifest="$TMP_WORK/source.$slot_index.$(printf '%s' "$run" | sha256_stream)"
    inventory_path "$source_entry" "$source_manifest" || {
      echo "REFUSE slot=$slot run=$run could not inventory source" >&2
      refused=1
      slot_can_link=0
      continue
    }
    source_hash=$(sha256_file "$source_manifest")
    source_count=$(wc -l < "$source_manifest" | tr -d '[:space:]')
    echo "INVENTORY slot=$slot run=$run entries=$source_count hash=$source_hash"
    if [ "$active" -eq 1 ]; then
      echo "DEFER active slot=$slot run=$run status=$status processes=$process_count"
      continue
    fi
    if [ "$APPLY" -eq 0 ]; then
      echo "WOULD-MIGRATE slot=$slot run=$run"
      continue
    fi

    destination="$CANONICAL_TARGET/$run"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      destination_manifest="$TMP_WORK/destination.$slot_index.$(printf '%s' "$run" | sha256_stream)"
      inventory_path "$destination" "$destination_manifest" || {
        echo "REFUSE collision slot=$slot run=$run destination could not be inventoried" >&2
        refused=1
        slot_can_link=0
        continue
      }
      if ! cmp -s "$source_manifest" "$destination_manifest"; then
        echo "REFUSE collision slot=$slot run=$run source_hash=$source_hash destination_hash=$(sha256_file "$destination_manifest")" >&2
        refused=1
        slot_can_link=0
        continue
      fi
      echo "VERIFIED-EXISTING slot=$slot run=$run hash=$source_hash"
    else
      run_key=$(printf '%s' "$run" | sha256_stream)
      stage_parent="$STAGE_ROOT/$slot/$run_key/$source_hash"
      stage_entry="$stage_parent/item"
      rm -rf "$stage_parent"
      mkdir -p "$stage_parent"
      if ! cp -Rp "$source_entry" "$stage_entry"; then
        echo "error: copy interrupted for slot=$slot run=$run; source preserved and staging retained at $stage_parent" >&2
        exit 1
      fi
      stage_manifest="$TMP_WORK/stage.$slot_index.$run_key"
      inventory_path "$stage_entry" "$stage_manifest" || {
        echo "error: staged copy could not be inventoried for slot=$slot run=$run; source preserved" >&2
        exit 1
      }
      if ! cmp -s "$source_manifest" "$stage_manifest"; then
        echo "error: staged copy is incomplete for slot=$slot run=$run; source preserved" >&2
        exit 1
      fi
      source_after="$TMP_WORK/source-after.$slot_index.$run_key"
      inventory_path "$source_entry" "$source_after" || {
        echo "DEFER changed slot=$slot run=$run source disappeared during copy"
        slot_can_link=0
        continue
      }
      if ! cmp -s "$source_manifest" "$source_after"; then
        echo "DEFER changed slot=$slot run=$run source_hash=$source_hash current_hash=$(sha256_file "$source_after")"
        slot_can_link=0
        continue
      fi
      sync
      inventory_path "$stage_entry" "$stage_manifest.after"
      if ! cmp -s "$source_manifest" "$stage_manifest.after"; then
        echo "error: staged copy changed after sync for slot=$slot run=$run; source preserved" >&2
        exit 1
      fi
      mv -n "$stage_entry" "$destination"
      if [ -e "$stage_entry" ] || [ -L "$stage_entry" ]; then
        destination_manifest="$TMP_WORK/destination-race.$slot_index.$run_key"
        inventory_path "$destination" "$destination_manifest" || true
        if [ ! -f "$destination_manifest" ] || ! cmp -s "$source_manifest" "$destination_manifest"; then
          echo "REFUSE collision slot=$slot run=$run destination appeared during publication" >&2
          refused=1
          slot_can_link=0
          continue
        fi
        rm -rf "$stage_entry"
      fi
      echo "COPIED slot=$slot run=$run hash=$source_hash"
    fi

    sync
    source_final="$TMP_WORK/source-final.$slot_index.$(printf '%s' "$run" | sha256_stream)"
    destination_final="$TMP_WORK/destination-final.$slot_index.$(printf '%s' "$run" | sha256_stream)"
    inventory_path "$source_entry" "$source_final" || {
      echo "REFUSE slot=$slot run=$run source changed before removal" >&2
      refused=1
      slot_can_link=0
      continue
    }
    inventory_path "$destination" "$destination_final" || {
      echo "REFUSE slot=$slot run=$run destination changed before removal" >&2
      refused=1
      slot_can_link=0
      continue
    }
    if ! cmp -s "$source_manifest" "$source_final" || ! cmp -s "$source_manifest" "$destination_final"; then
      echo "DEFER changed slot=$slot run=$run during durable verification"
      slot_can_link=0
      continue
    fi
    if slot_still_available "$slot" "$path"; then
      :
    else
      recheck_rc=$?
      slot_can_link=0
      if [ "$recheck_rc" -eq 1 ]; then
        echo "DEFER active-changed slot=$slot run=$run before source retirement"
      else
        echo "REFUSE slot=$slot run=$run could not confirm lane remained available before source retirement" >&2
        refused=1
      fi
      continue
    fi
    echo "VERIFIED slot=$slot run=$run hash=$source_hash"
    retire_dir="$slot_real/data/local/.dos-3ndcm-review-migrated/$run/$source_hash"
    retire_entry="$retire_dir/item"
    rm -rf "$retire_dir"
    mkdir -p "$retire_dir"
    if ! mv -n "$source_entry" "$retire_entry" || [ -e "$source_entry" ] || [ -L "$source_entry" ]; then
      echo "REFUSE slot=$slot run=$run source could not be atomically retired after verification" >&2
      refused=1
      slot_can_link=0
      continue
    fi
    sync
    retire_manifest="$TMP_WORK/retired.$slot_index.$(printf '%s' "$run" | sha256_stream)"
    if ! inventory_path "$retire_entry" "$retire_manifest" \
      || ! cmp -s "$source_manifest" "$retire_manifest"; then
      echo "REFUSE slot=$slot run=$run source changed during atomic retirement; retained outside the canonical namespace" >&2
      if [ ! -e "$source_entry" ] && [ ! -L "$source_entry" ]; then
        mv -n "$retire_entry" "$source_entry" || true
      fi
      refused=1
      slot_can_link=0
      continue
    fi
    rm -rf "$retire_dir"
    sync
    echo "REMOVED slot=$slot run=$run source=$source_entry"
  done < "$entries"

  if [ "$slot_can_link" -eq 1 ] && [ -d "$reviews" ] \
    && [ -z "$(find "$reviews" -mindepth 1 -print -quit)" ]; then
    if [ "$APPLY" -eq 1 ]; then
      if rmdir "$reviews" && ln -s "$CANONICAL_LINK" "$reviews"; then
        echo "LINKED slot=$slot target=$CANONICAL_LINK"
      else
        echo "REFUSE slot=$slot drained review directory could not be linked path=$reviews" >&2
        refused=1
      fi
    fi
  fi
done < <(jq -r '.[] | [.name,.path,.status,(.processes|length)] | @tsv' "$POOL_JSON")

if [ "$refused" -ne 0 ]; then
  echo "migration refused one or more unsafe pool entries; no refused source was removed" >&2
  exit 1
fi
if [ "$APPLY" -eq 0 ]; then
  echo "PREFLIGHT complete: no files copied, removed, or linked"
else
  echo "APPLY complete: active or changing runs, if any, remain deferred"
fi
