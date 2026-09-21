#!/usr/bin/env bash
# fm-memory-migrate.sh - export an OpenViking workspace into the plain-markdown
# memory store, proving nothing is lost.
#
# Usage:
#   fm-memory-migrate.sh migrate [--source <dir>] [--dest <dir>]
#       [--archive <dir>] [--memories-dir <dir>] [--dry-run]
#   fm-memory-migrate.sh verify  [--dest <dir>] [--manifest <file>]
#
# docs/memory.md owns the operator contract and rollback story. This header
# owns flags, the source-discovery order, the manifest format, and exit codes.
#
# Source: the OpenViking data workspace, default $FM_OV_HOME/data with
# FM_OV_HOME defaulting to ~/.openviking. The memories tree is located by, in
# order: --memories-dir, <source>/user/default/memories, <source>/memories,
# then <source>/data/user/default/memories. When none of those exists the run
# fails and --memories-dir is the way to pin a variant layout; there is no
# search fallback. Memories are copied into <dest> (default: fm-memory.sh's resolved
# store dir) preserving their relative layout, so preferences/x.md lands at
# <dest>/preferences/x.md.
#
# Every other *.md file under the source - sessions, wiki-layer, resources,
# skills, peers, privacy - is copied under <archive> (default
# $FM_HOME/data/memory-archive) preserving its source-relative path, except
# OpenViking internals (_system/, vectordb/, logs/) and dot-directories, which
# are skipped. Nothing outside *.md is exported; the vector index and queue
# are deliberately left behind.
#
# The migration never writes to or deletes from the source, and never deletes
# from the destination. A re-run refreshes a destination the last migration
# wrote and that still matches its recorded hash, and restores a missing
# destination; every other destination that already exists - one edited in the
# new store since the last migration, or one the migration never wrote at all
# (a memory the operator created first), or one whose recorded hash the newest
# manifest does not carry - is left untouched and reported as skipped-and-kept.
# There is no force or overwrite flag. --dest and --archive must resolve outside
# --source; an output directory inside the source is refused as a usage error
# before anything is planned.
# Each run writes <dest>/.migration/manifest-<utc>.txt, plus a header: one
# "<src-rel>\t<sha256>\t<dest-path>" row per exported file, and one
# "#skipped\t<recorded-sha256>\t<dest-path>" row per kept destination (the
# recorded hash is what the migration last wrote, or the source hash it
# declined to write when the destination is foreign, so later runs keep
# detecting drift). `verify` recomputes every exported destination hash in the newest (or
# --manifest) manifest and reports verified/skipped/missing/mismatch counts; the
# migrate run performs the same verification before reporting success.
#
# Exit codes: 0 success; 2 usage; 3 source or memories tree not found;
# 4 verification failed (missing or mismatched destination files).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
OV_HOME="${FM_OV_HOME:-$HOME/.openviking}"
work=

cleanup() {
  [ -n "${work:-}" ] && rm -rf -- "$work"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-memory-migrate.sh migrate [--source <dir>] [--dest <dir>]
      [--archive <dir>] [--memories-dir <dir>] [--dry-run]
  fm-memory-migrate.sh verify  [--dest <dir>] [--manifest <file>]
EOF
}

die() {
  printf 'memory-migrate: %s\n' "$1" >&2
  exit "${2:-2}"
}

sha256_file() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  else
    printf 'memory-migrate: no sha256 tool (shasum or sha256sum) on PATH\n' >&2
    return 1
  fi
  [ -n "$out" ] || { printf 'memory-migrate: cannot hash %s\n' "$1" >&2; return 1; }
  printf '%s' "$out"
}

canonical_path() {
  local path=$1 out='' seg
  [ -n "$path" ] || { printf '/'; return 0; }
  local -a segs
  local IFS='/'
  read -r -a segs <<< "$path"
  for seg in "${segs[@]}"; do
    case "$seg" in
      ''|'.') continue ;;
      '..') out=${out%/*}; continue ;;
    esac
    out="$out/$seg"
  done
  [ -n "$out" ] || out='/'
  printf '%s' "$out"
}

normalize_dir() {
  local p=$1 rest=''
  [ -n "$p" ] || { printf '%s' "$p"; return 0; }
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  while [ ! -d "$p" ] && [ "$p" != '/' ]; do
    rest="/${p##*/}$rest"
    p=${p%/*}
    [ -n "$p" ] || p='/'
  done
  local base
  base=$(cd "$p" 2>/dev/null && pwd -P)
  [ -n "$base" ] || die "cannot resolve directory: $1"
  canonical_path "${base%/}$rest"
}

resolve_dest() {
  local store
  store=$("$SCRIPT_DIR/fm-memory.sh" dir) \
    || die "cannot resolve the store dir; $SCRIPT_DIR/fm-memory.sh dir failed"
  [ -n "$store" ] || die "cannot resolve the store dir; $SCRIPT_DIR/fm-memory.sh dir was empty"
  printf '%s' "$store"
}

find_memories_dir() {
  local src=$1 rel
  for rel in user/default/memories memories data/user/default/memories; do
    if [ -d "$src/$rel" ]; then
      printf '%s' "$src/$rel"
      return 0
    fi
  done
  return 1
}

is_internal_rel() {
  case "/$1/" in
    */_system/*|*/vectordb/*|*/logs/*|*/.*/*) return 0 ;;
  esac
  return 1
}

cmd_migrate() {
  local source="$OV_HOME/data" dest='' archive='' memories_dir='' dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die "--source needs a value"; source=$2; shift 2 ;;
      --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest=$2; shift 2 ;;
      --archive) [ $# -ge 2 ] || die "--archive needs a value"; archive=$2; shift 2 ;;
      --memories-dir) [ $# -ge 2 ] || die "--memories-dir needs a value"; memories_dir=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done
  if [ -z "$dest" ]; then
    dest=$(resolve_dest) || exit 2
  fi
  dest=$(normalize_dir "$dest") || exit 2
  [ -n "$archive" ] || archive=$FM_HOME/data/memory-archive
  archive=$(normalize_dir "$archive") || exit 2
  source=$(normalize_dir "$source") || exit 2
  [ -d "$source" ] || die "source not found: $source" 3
  case "$dest" in "$source"|"$source"/*) die "--dest must resolve outside --source: $dest" 2 ;; esac
  case "$archive" in "$source"|"$source"/*) die "--archive must resolve outside --source: $archive" 2 ;; esac

  if [ -z "$memories_dir" ]; then
    memories_dir=$(find_memories_dir "$source") \
      || die "no memories tree under $source; pass --memories-dir" 3
  fi
  memories_dir=$(normalize_dir "$memories_dir") || exit 2
  [ -d "$memories_dir" ] || die "memories dir not found: $memories_dir" 3
  local memories_rel=${memories_dir#"$source"/}

  local manifest
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-mem-migrate.XXXXXX") || die "mktemp failed"

  # Plan: memories -> dest (relative to memories dir), other markdown ->
  # archive (relative to source root). Findings are relative paths so the
  # dot-component exclusion cannot trip on a dot-directory above the roots.
  : > "$work/plan"
  local count_mem=0 count_arc=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel=${rel#./}
    printf '%s\t%s\t%s\n' "$memories_dir/$rel" "$rel" "$dest/$rel" >> "$work/plan"
    count_mem=$((count_mem + 1))
  done <<EOF
$(cd "$memories_dir" && find . -type f -name '*.md' ! -path '*/.*' | sort)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel=${rel#./}
    case "$rel" in "${memories_rel}"/*) continue ;; esac
    is_internal_rel "$rel" && continue
    printf '%s\t%s\t%s\n' "$source/$rel" "$rel" "$archive/$rel" >> "$work/plan"
    count_arc=$((count_arc + 1))
  done <<EOF
$(cd "$source" && find . -type f -name '*.md' ! -path '*/.*' | sort)
EOF

  printf 'source: %s\nmemories: %s (%s files)\ndest: %s\narchive: %s (%s files)\n' \
    "$source" "$memories_dir" "$count_mem" "$dest" "$archive" "$count_arc"
  [ "$count_mem" -gt 0 ] || die "memories tree holds no markdown: $memories_dir" 3
  if [ "$dry_run" -eq 1 ]; then
    printf 'dry-run: no files written\n'
    return 0
  fi

  # Copy, then record the manifest.
  manifest=$dest/.migration/manifest-$(date -u +%Y%m%dT%H%M%SZ).txt
  mkdir -p "$dest/.migration" || die "cannot create $dest/.migration"
  {
    printf '# fm-memory-migrate manifest\n'
    printf '# source: %s\n# memories-dir: %s\n# dest: %s\n# archive: %s\n' \
      "$source" "$memories_dir" "$dest" "$archive"
    printf '# at: %s\n' "$(date -u +%FT%TZ)"
  } > "$work/manifest.head"
  : > "$work/manifest.rows"

  local prev_manifest
  prev_manifest=$(find "$dest/.migration" -name 'manifest-*.txt' 2>/dev/null | sort | tail -n1)

  local fails=0 skipped=0
  while IFS=$'\t' read -r src_f rel dst_f; do
    [ -n "$src_f" ] || continue
    local src_sum dst_dir dst_sum prev_sum=''
    if [ -f "$dst_f" ]; then
      if [ -n "$prev_manifest" ]; then
        prev_sum=$(awk -F'\t' -v k="$dst_f" 'NF >= 3 && $3 == k { h = $2 } END { print h }' "$prev_manifest")
      fi
      if [ -n "$prev_sum" ]; then
        dst_sum=$(sha256_file "$dst_f") || { fails=$((fails + 1)); continue; }
        if [ "$dst_sum" != "$prev_sum" ]; then
          printf 'skip: %s (edited in store since last migration; kept)\n' "$dst_f"
          printf '#skipped\t%s\t%s\n' "$prev_sum" "$dst_f" >> "$work/manifest.rows"
          skipped=$((skipped + 1))
          continue
        fi
      else
        src_sum=$(sha256_file "$src_f") || { fails=$((fails + 1)); continue; }
        dst_sum=$(sha256_file "$dst_f") || { fails=$((fails + 1)); continue; }
        if [ "$dst_sum" != "$src_sum" ]; then
          printf 'skip: %s (exists in store, not written by this migration; kept)\n' "$dst_f"
          printf '#skipped\t%s\t%s\n' "$src_sum" "$dst_f" >> "$work/manifest.rows"
          skipped=$((skipped + 1))
          continue
        fi
      fi
    fi
    src_sum=$(sha256_file "$src_f") || { fails=$((fails + 1)); continue; }
    dst_dir=$(dirname "$dst_f")
    mkdir -p "$dst_dir" || { printf 'error: cannot create %s\n' "$dst_dir" >&2; fails=$((fails + 1)); continue; }
    cp -p "$src_f" "$dst_f" || { printf 'error: copy failed %s\n' "$src_f" >&2; fails=$((fails + 1)); continue; }
    dst_sum=$(sha256_file "$dst_f") || { fails=$((fails + 1)); continue; }
    if [ "$src_sum" != "$dst_sum" ]; then
      printf 'error: hash mismatch after copy: %s\n' "$dst_f" >&2
      fails=$((fails + 1))
      continue
    fi
    printf '%s\t%s\t%s\n' "$rel" "$src_sum" "$dst_f" >> "$work/manifest.rows"
  done < "$work/plan"

  cat "$work/manifest.head" > "$manifest"
  cat "$work/manifest.rows" >> "$manifest"
  printf 'manifest: %s\n' "$manifest"

  [ "$fails" -eq 0 ] || die "$fails file(s) failed to copy" 4
  verify_manifest "$manifest" || exit 4

  if [ "$skipped" -gt 0 ]; then
    printf 'planned: %s memories, %s archived; %s skipped-and-kept (existing destination not written by migration)\n' \
      "$count_mem" "$count_arc" "$skipped"
  else
    printf 'planned: %s memories, %s archived; all hashes verified\n' "$count_mem" "$count_arc"
  fi

  if [ -x "$SCRIPT_DIR/fm-memory.sh" ] && command -v node >/dev/null 2>&1; then
    FM_MEMORY_DIR=$dest "$SCRIPT_DIR/fm-memory.sh" reindex >/dev/null 2>&1 \
      || printf 'warning: reindex failed; run fm-memory.sh reindex\n' >&2
  fi
}

verify_manifest() {
  local manifest=$1 total=0 ok=0 missing=0 mismatch=0 skipped=0 rel sum dst cur
  [ -f "$manifest" ] || die "manifest not found: $manifest" 2
  while IFS=$'\t' read -r rel sum dst; do
    case "$rel" in
      '#skipped') skipped=$((skipped + 1)); continue ;;
      ''|\#*) continue ;;
    esac
    total=$((total + 1))
    if [ ! -f "$dst" ]; then
      missing=$((missing + 1))
      printf 'missing: %s\n' "$dst" >&2
      continue
    fi
    cur=$(sha256_file "$dst") || cur=''
    if [ -n "$cur" ] && [ "$cur" = "$sum" ]; then
      ok=$((ok + 1))
    else
      mismatch=$((mismatch + 1))
      printf 'mismatch: %s\n' "$dst" >&2
    fi
  done < "$manifest"
  printf 'verify: %s/%s verified' "$ok" "$total"
  [ "$skipped" -eq 0 ] || printf ', %s skipped-and-kept' "$skipped"
  [ "$missing" -eq 0 ] || printf ', %s missing' "$missing"
  [ "$mismatch" -eq 0 ] || printf ', %s mismatched' "$mismatch"
  printf '\n'
  [ "$ok" -eq "$total" ] && { [ "$total" -gt 0 ] || [ "$skipped" -gt 0 ]; }
}

cmd_verify() {
  local dest='' manifest=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest=$2; shift 2 ;;
      --manifest) [ $# -ge 2 ] || die "--manifest needs a value"; manifest=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done
  if [ -z "$manifest" ]; then
    if [ -z "$dest" ]; then
      dest=$(resolve_dest) || exit 2
    fi
    manifest=$(find "$dest/.migration" -name 'manifest-*.txt' 2>/dev/null | sort | tail -n1)
    [ -n "$manifest" ] || die "no manifest under $dest/.migration" 2
  fi
  verify_manifest "$manifest" || exit 4
}

cmd=${1:-migrate}
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  migrate|verify) ;;
  *) usage; die "unknown command: $cmd" ;;
esac
shift
case "$cmd" in
  migrate) cmd_migrate "$@" ;;
  verify) cmd_verify "$@" ;;
esac
