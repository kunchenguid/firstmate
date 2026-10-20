#!/usr/bin/env bash
# fm-artifact-lib.sh - the one owner of a worker's artifact lineage.
#
# WHY THIS EXISTS. A secondmate home's parent channel already carried a
# `report=` document pointer and a `pr=` pointer, and both say WHERE an outcome
# lives, not WHICH bytes were verified. A conversational summary is not
# evidence: it cannot be re-checked once the worker's disposable worktree is
# torn down, and forwarding a worker transcript as the result makes the parent
# consume raw worker text instead of a status. This library makes a WorkerResult
# artifact-first: a manifest at data/<task>/artifacts.json names each artifact
# by kind and path and pins it with the full SHA-256 of its bytes.
#
# The contract (docs/artifact-lineage.md):
#   - artifact kinds are a closed allowlist (patch, test-log, review-report,
#     report, trace). transcript, chat, session, and conversation are NOT
#     artifacts and are refused, so a transcript cannot be forwarded as a
#     WorkerResult.
#   - every path is the home-relative `data/<task>/...` form and resolves to a
#     regular, non-symlinked file under the data directory; the check is a
#     resolving one, never a textual prefix test.
#   - the manifest is written atomically and verified by recomputing every
#     hash, so a changed or missing artifact fails instead of reading intact.
#   - the parent channel carries a pointer plus the manifest digest
#     (`artifacts=data/<task>/artifacts.json artifacts_sha256=<hex>`), never the
#     artifact bodies.
#
# Sourced by bin/fm-artifact-manifest.sh and bin/fm-inactive-reconcile.sh.
# No side effects on source.

# A task id is used as a directory component, so it is accepted only when it is
# path-safe: no empty value, leading dot, slash, or character outside
# [A-Za-z0-9._-].
fm_artifact_task_valid() {  # <task>
  local task=${1-}
  case "$task" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The closed allowlist. A transcript/chat/session is deliberately absent: the
# contract prohibits transcript forwarding rather than merely discouraging it.
fm_artifact_kind_valid() {  # <kind>
  case "${1-}" in
    patch|test-log|review-report|report|trace|manifest) return 0 ;;
  esac
  return 1
}

# Full 64-hex SHA-256 of <file>; non-zero when no hasher is available.
fm_artifact_sha256() {  # <file>
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Validate the home-relative artifact spelling. Only data/<task>/... is
# accepted, with no parent traversal, no empty component, and no character a
# status line or the JSON writer would have to escape.
fm_artifact_rel_valid() {  # <task> <rel>
  local task=$1 rel=${2-}
  case "$rel" in
    "data/$task/"*) ;;
    *) return 1 ;;
  esac
  case "/$rel/" in */../*|*/./*) return 1 ;; esac
  case "$rel" in *'//'*) return 1 ;; esac
  case "$rel" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
}

# Resolve <rel> to a real path under <data-dir>, rejecting a symlink in place
# of the artifact or of any directory it is reached through. Prints the
# resolved path.
fm_artifact_resolve() {  # <data-dir> <task> <rel> -> absolute path
  local data=$1 task=$2 rel=$3 base real path
  fm_artifact_task_valid "$task" || return 1
  fm_artifact_rel_valid "$task" "$rel" || return 1
  path="$data/${rel#data/}"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  base=$(CDPATH='' cd -- "$data" 2>/dev/null && pwd -P) || return 1
  real=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  case "$real" in
    "$base"|"$base"/*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$path"
}

# Write a manifest atomically from <kind>=<rel> pairs. Entries are sorted so the
# same inputs always produce the same bytes. Prints the manifest path.
fm_artifact_manifest_write() {  # <data-dir> <task> <kind>=<rel>...
  local data=$1 task=$2 entry kind rel path hash bytes dir out tmp sorted
  local -a entries=()
  fm_artifact_task_valid "$task" || return 2
  shift 2
  [ "$#" -gt 0 ] || return 2
  for entry in "$@"; do
    case "$entry" in
      *=*) ;;
      *) return 3 ;;
    esac
    kind=${entry%%=*}
    rel=${entry#*=}
    fm_artifact_kind_valid "$kind" || return 3
    path=$(fm_artifact_resolve "$data" "$task" "$rel") || return 3
    hash=$(fm_artifact_sha256 "$path") || return 4
    [ "${#hash}" -eq 64 ] || return 4
    bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || return 4
    case "$bytes" in ''|*[!0-9]*) return 4 ;; esac
    entries+=("$kind"$'\t'"$rel"$'\t'"$hash"$'\t'"$bytes")
  done
  sorted=$(printf '%s\n' "${entries[@]}" | LC_ALL=C sort) || return 4
  dir="$data/$task"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 5
  out="$dir/artifacts.json"
  tmp=$(umask 077; mktemp "$dir/.artifacts.XXXXXX") || return 5
  {
    printf '{\n'
    printf '  "schema": "fm-artifact-manifest.v1",\n'
    printf '  "task": "%s",\n' "$task"
    printf '  "artifacts": [\n'
    local first=1 line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=$'\t' read -r kind rel hash bytes <<< "$line"
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    {"kind": "%s", "path": "%s", "sha256": "%s", "bytes": %s}' \
        "$kind" "$rel" "$hash" "$bytes"
    done <<< "$sorted"
    printf '\n  ]\n'
    printf '}\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 5; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 5; }
  mv -f -- "$tmp" "$out" || { rm -f -- "$tmp"; return 5; }
  printf '%s\n' "$out"
}

# Read one JSON string field from <line>; the writer's own validated charset
# means no escaping is possible.
_fm_artifact_json_field() {  # <line> <key>
  printf '%s\n' "$1" | sed -n "s/.*\"$2\": \"\\([^\"]*\\)\".*/\\1/p"
}

# The size field is the manifest's only unquoted JSON value.
_fm_artifact_json_size() {  # <line>
  printf '%s\n' "$1" | sed -n 's/.*"bytes": \([0-9][0-9]*\).*/\1/p'
}

# Verify every entry against the artifact bytes. Returns 0 only when the schema,
# task, every path, and every hash agree; prints a one-line reason on failure.
fm_artifact_manifest_verify() {  # <data-dir> <task> <manifest>
  local data=$1 task=$2 manifest=$3 line kind rel hash bytes path actual expected
  local seen=''
  fm_artifact_task_valid "$task" || { printf 'invalid task id\n'; return 1; }
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || { printf 'manifest is not a regular file\n'; return 1; }
  grep -Fxq '  "schema": "fm-artifact-manifest.v1",' "$manifest" 2>/dev/null \
    || grep -Fxq '  "schema": "fm-artifact-manifest.v1"' "$manifest" 2>/dev/null \
    || { printf 'unknown manifest schema\n'; return 1; }
  grep -Fxq "  \"task\": \"$task\"," "$manifest" 2>/dev/null \
    || grep -Fxq "  \"task\": \"$task\"" "$manifest" 2>/dev/null \
    || { printf 'manifest task does not match\n'; return 1; }
  while IFS= read -r line; do
    case "$line" in
      '    {'*'}') ;;
      *) continue ;;
    esac
    kind=$(_fm_artifact_json_field "$line" kind)
    rel=$(_fm_artifact_json_field "$line" path)
    hash=$(_fm_artifact_json_field "$line" sha256)
    bytes=$(_fm_artifact_json_size "$line")
    fm_artifact_kind_valid "$kind" || { printf 'artifact kind is not allowed: %s\n' "$kind"; return 1; }
    fm_artifact_rel_valid "$task" "$rel" || { printf 'artifact path is not confined to data/%s/: %s\n' "$task" "$rel"; return 1; }
    case "$seen" in
      *$'\n'"$rel"$'\n'*) printf 'duplicate artifact path: %s\n' "$rel"; return 1 ;;
    esac
    seen="$seen"$'\n'"$rel"$'\n'
    path=$(fm_artifact_resolve "$data" "$task" "$rel") || { printf 'artifact is missing or unsafe: %s\n' "$rel"; return 1; }
    actual=$(fm_artifact_sha256 "$path") || { printf 'artifact hash is unavailable: %s\n' "$rel"; return 1; }
    [ "$hash" = "$actual" ] || { printf 'artifact hash mismatch: %s\n' "$rel"; return 1; }
    expected=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || { printf 'artifact size is unavailable: %s\n' "$rel"; return 1; }
    case "$bytes" in
      ''|*[!0-9]*) printf 'artifact size is malformed: %s\n' "$rel"; return 1 ;;
    esac
    [ "$bytes" = "$expected" ] || { printf 'artifact size mismatch: %s\n' "$rel"; return 1; }
  done < "$manifest"
  [ -n "$seen" ] || { printf 'manifest has no artifacts\n'; return 1; }
  return 0
}

# The parent-channel suffix for <task>, or non-zero when no verified manifest
# exists. The digest names the exact manifest bytes the parent will read.
fm_artifact_manifest_ref() {  # <data-dir> <task>
  local data=$1 task=$2 rel manifest digest
  fm_artifact_task_valid "$task" || return 1
  rel="data/$task/artifacts.json"
  manifest="$data/$task/artifacts.json"
  fm_artifact_manifest_verify "$data" "$task" "$manifest" >/dev/null || return 1
  digest=$(fm_artifact_sha256 "$manifest") || return 1
  [ "${#digest}" -eq 64 ] || return 1
  printf 'artifacts=%s artifacts_sha256=%s\n' "$rel" "$digest"
}
