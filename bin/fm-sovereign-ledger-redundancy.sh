#!/usr/bin/env bash
# fm-sovereign-ledger-redundancy.sh - make, advance, and verify an independent local ledger replica.
#
# Usage:
#   fm-sovereign-ledger-redundancy.sh snapshot <primary-ledger-dir> <replica-ledger-dir>
#   fm-sovereign-ledger-redundancy.sh refresh <primary-ledger-dir> <replica-ledger-dir>
#   fm-sovereign-ledger-redundancy.sh verify <primary-ledger-dir> <replica-ledger-dir>
#
# snapshot creates a complete staging bundle then atomically publishes it into an absent replica path.
# refresh advances only a verifying byte-exact ledger.tsv prefix while every other bundle file is identical.
# verify fails loudly on containment, a stale prefix, a divergence, symlinks, non-regular files, an incomplete layout, or overlapping file-identity sets.
# No replica-controlled code runs until all bundle bytes have been compared to the primary.
# This script never admits, rewrites, repairs, or attributes a ruling.
set -euo pipefail

BUNDLE_MEMBER_COUNT=4
BUNDLE_ENTRIES=

die() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0" >&2
  exit 2
}

canonical_dir() {
  [ -d "$1" ] || die "ledger directory does not exist: $1"
  (
    cd "$1"
    pwd -P
  )
}

bundle_manifest() {
  printf '%s\n' CONTRACT.md fm-sovereign-ledger.sh ledger.tsv tests.sh
}

collect_bundle_entries() {
  local dir=$1 count
  if ! count=$(find "$dir" -mindepth 1 -maxdepth 1 -exec /bin/sh -c '
    for entry do printf "x\n"; done
  ' sh {} + | wc -l | tr -d '[:space:]'); then
    die "could not enumerate ledger bundle: $dir"
  fi
  [ "$count" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "ledger bundle must contain exactly $BUNDLE_MEMBER_COUNT manifest members, found $count: $dir"
  BUNDLE_ENTRIES=$(bundle_manifest)
}

require_bundle() {
  local dir=$1 entry checked=0
  BUNDLE_ENTRIES=$(bundle_manifest)
  while IFS= read -r entry; do
    [ -e "$dir/$entry" ] || die "ledger bundle is incomplete: missing $dir/$entry"
    [ -L "$dir/$entry" ] && die "ledger bundle contains a symlink: $dir/$entry"
    [ -f "$dir/$entry" ] || die "ledger bundle contains a non-regular file: $dir/$entry"
    checked=$((checked + 1))
  done <<< "$BUNDLE_ENTRIES"
  collect_bundle_entries "$dir"
  [ "$checked" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "ledger bundle manifest check read $checked of $BUNDLE_MEMBER_COUNT members: $dir"
  [ -x "$dir/fm-sovereign-ledger.sh" ] || die "ledger verifier is not executable: $dir/fm-sovereign-ledger.sh"
}

compare_layout() {
  local primary=$1 replica=$2 primary_entries replica_entries
  collect_bundle_entries "$primary"
  primary_entries=$BUNDLE_ENTRIES
  collect_bundle_entries "$replica"
  replica_entries=$BUNDLE_ENTRIES
  [ "$primary_entries" = "$replica_entries" ] || die "replica bundle layout differs from primary"
}

compare_files() {
  local primary=$1 replica=$2 skip=${3:-} entry compared=0 expected=$BUNDLE_MEMBER_COUNT
  collect_bundle_entries "$primary"
  [ -z "$skip" ] || expected=$((expected - 1))
  while IFS= read -r entry; do
    [ "$entry" = "$skip" ] && continue
    cmp -s "$primary/$entry" "$replica/$entry" \
      || die "replica differs from primary: $entry"
    compared=$((compared + 1))
  done <<< "$BUNDLE_ENTRIES"
  [ "$compared" -eq "$expected" ] \
    || die "byte comparison read $compared of $expected required bundle members"
}

portable_file_identity() {
  local follow=$1 path=$2 identity
  if [ "$follow" = true ]; then
    if identity=$(stat -L -f '%d:%i' "$path" 2>/dev/null); then
      :
    elif identity=$(stat -L -c '%d:%i' "$path" 2>/dev/null); then
      :
    else
      return 1
    fi
  elif identity=$(stat -f '%d:%i' "$path" 2>/dev/null); then
    :
  elif identity=$(stat -c '%d:%i' "$path" 2>/dev/null); then
    :
  else
    return 1
  fi
  printf '%s\n' "$identity" | LC_ALL=C grep -Eq '^[0-9]+:[0-9]+$' || return 1
  printf '%s\n' "$identity"
}

file_lstat_identity() {
  portable_file_identity false "$1"
}

file_stat_identity() {
  portable_file_identity true "$1"
}

require_independent_bundle_files() {
  local primary=$1 replica=$2 entry index=0 replica_index primary_index
  local primary_lstat replica_lstat primary_stat replica_stat
  local -a entries primary_lstats replica_lstats primary_stats replica_stats
  collect_bundle_entries "$primary"
  while IFS= read -r entry; do
    entries[index]=$entry
    primary_lstat=$(file_lstat_identity "$primary/$entry") \
      || die "could not establish a portable file identity: $primary/$entry"
    replica_lstat=$(file_lstat_identity "$replica/$entry") \
      || die "could not establish a portable file identity: $replica/$entry"
    primary_stat=$(file_stat_identity "$primary/$entry") \
      || die "could not establish a portable file identity: $primary/$entry"
    replica_stat=$(file_stat_identity "$replica/$entry") \
      || die "could not establish a portable file identity: $replica/$entry"
    primary_lstats[index]=$primary_lstat
    replica_lstats[index]=$replica_lstat
    primary_stats[index]=$primary_stat
    replica_stats[index]=$replica_stat
    index=$((index + 1))
  done <<< "$BUNDLE_ENTRIES"
  [ "$index" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "identity verification read $index of $BUNDLE_MEMBER_COUNT required bundle members"
  for ((replica_index = 0; replica_index < BUNDLE_MEMBER_COUNT; replica_index++)); do
    for ((primary_index = 0; primary_index < BUNDLE_MEMBER_COUNT; primary_index++)); do
      if [ "${replica_lstats[$replica_index]}" = "${primary_lstats[$primary_index]}" ]; then
        if [ "${entries[$replica_index]}" = "${entries[$primary_index]}" ]; then
          die "replica ${entries[$replica_index]} shares the primary lstat identity (device:inode), not a separate file"
        fi
        die "replica ${entries[$replica_index]} shares storage with primary member ${entries[$primary_index]} by lstat identity (device:inode)"
      fi
      if [ "${replica_stats[$replica_index]}" = "${primary_stats[$primary_index]}" ]; then
        if [ "${entries[$replica_index]}" = "${entries[$primary_index]}" ]; then
          die "replica ${entries[$replica_index]} resolves to the primary object (device:inode), not a separate file"
        fi
        die "replica ${entries[$replica_index]} resolves to primary member ${entries[$primary_index]} by stat identity (device:inode)"
      fi
    done
  done
}

require_noncontained_pair() {
  local primary=$1 replica=$2
  [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
  case "$primary/" in "$replica/"*) die "primary and replica directories must not contain one another" ;; esac
  case "$replica/" in "$primary/"*) die "primary and replica directories must not contain one another" ;; esac
}

verify_with_primary() {
  local primary=$1 subject=$2
  LEDGER_DIR="$subject" "$primary/fm-sovereign-ledger.sh" verify >/dev/null \
    || die "primary ledger verifier rejected $subject/ledger.tsv"
}

replica_is_prefix() {
  local primary=$1 replica=$2 primary_lines replica_lines
  primary_lines=$(wc -l < "$primary/ledger.tsv" | tr -d ' ')
  replica_lines=$(wc -l < "$replica/ledger.tsv" | tr -d ' ')
  [ "$replica_lines" -gt 0 ] || return 1
  [ "$primary_lines" -gt "$replica_lines" ] || return 1
  head -n "$replica_lines" "$primary/ledger.tsv" | cmp -s - "$replica/ledger.tsv"
}

preflight_pair() {
  local primary=$1 replica=$2
  require_bundle "$primary"
  require_bundle "$replica"
  compare_layout "$primary" "$replica"
  compare_files "$primary" "$replica" ledger.tsv
}

verify_exact_pair() {
  local primary=$1 replica=$2
  preflight_pair "$primary" "$replica"
  compare_files "$primary" "$replica"
  require_independent_bundle_files "$primary" "$replica"
  verify_with_primary "$primary" "$primary"
  verify_with_primary "$primary" "$replica"
}

copy_bundle() {
  local primary=$1 replica=$2 entry copied=0
  umask 077
  collect_bundle_entries "$primary"
  while IFS= read -r entry; do
    cp -p "$primary/$entry" "$replica/$entry"
    copied=$((copied + 1))
  done <<< "$BUNDLE_ENTRIES"
  [ "$copied" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "bundle copy read $copied of $BUNDLE_MEMBER_COUNT required members"
}

copy_ledger_atomically() {
  local primary=$1 replica=$2 parent base tmp
  parent=$(dirname "$replica")
  base=$(basename "$replica")
  tmp=$(mktemp "$parent/.${base}.ledger.tsv.tmp.XXXXXX") \
    || die "could not create refresh staging file beside replica"
  umask 077
  if ! cp -p "$primary/ledger.tsv" "$tmp"; then
    rm -f -- "$tmp"
    die "could not stage primary ledger.tsv for refresh"
  fi
  if ! mv "$tmp" "$replica/ledger.tsv"; then
    rm -f -- "$tmp"
    die "could not publish refreshed replica ledger.tsv"
  fi
}

cmd_snapshot() {
  local primary=$1 replica_input=$2 replica parent base stage
  primary=$(canonical_dir "$primary")
  if [ -e "$replica_input" ]; then
    replica=$(canonical_dir "$replica_input")
    require_noncontained_pair "$primary" "$replica"
    verify_exact_pair "$primary" "$replica"
    printf 'SNAPSHOT PASS (replica already identical: %s)\n' "$replica"
    return
  fi
  require_bundle "$primary"
  verify_with_primary "$primary" "$primary"
  parent=$(dirname "$replica_input")
  [ -d "$parent" ] || die "replica parent directory does not exist: $parent"
  parent=$(canonical_dir "$parent")
  base=$(basename "$replica_input")
  require_noncontained_pair "$primary" "$parent/$base"
  stage=$(mktemp -d "$parent/.${base}.stage.XXXXXX") \
    || die "could not create replica staging directory"
  trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
  copy_bundle "$primary" "$stage"
  verify_exact_pair "$primary" "$stage"
  mv "$stage" "$replica_input"
  stage=
  trap - EXIT HUP INT TERM
  printf 'SNAPSHOT PASS (replica created: %s)\n' "$(canonical_dir "$replica_input")"
}

cmd_refresh() {
  local primary replica
  primary=$(canonical_dir "$1")
  replica=$(canonical_dir "$2")
  require_noncontained_pair "$primary" "$replica"
  preflight_pair "$primary" "$replica"
  verify_with_primary "$primary" "$primary"
  verify_with_primary "$primary" "$replica"
  replica_is_prefix "$primary" "$replica" \
    || die "replica is not a verified byte-exact append-only prefix of primary"
  copy_ledger_atomically "$primary" "$replica"
  verify_exact_pair "$primary" "$replica"
  printf 'REFRESH PASS (replica advanced to primary)\n'
}

cmd_verify() {
  local primary replica
  primary=$(canonical_dir "$1")
  replica=$(canonical_dir "$2")
  require_noncontained_pair "$primary" "$replica"
  preflight_pair "$primary" "$replica"
  if ! cmp -s "$primary/ledger.tsv" "$replica/ledger.tsv"; then
    verify_with_primary "$primary" "$primary"
    verify_with_primary "$primary" "$replica"
    replica_is_prefix "$primary" "$replica" \
      && die "replica is a verified stale prefix; run refresh to advance it"
    die "replica ledger.tsv diverges from primary"
  fi
  verify_exact_pair "$primary" "$replica"
  printf 'REDUNDANCY VERIFY PASS (exact 4-member manifest byte-read; primary and replica identity sets disjoint)\n'
}

case "${1:-}" in
  snapshot) shift; [ "$#" -eq 2 ] || usage; cmd_snapshot "$@" ;;
  refresh) shift; [ "$#" -eq 2 ] || usage; cmd_refresh "$@" ;;
  verify) shift; [ "$#" -eq 2 ] || usage; cmd_verify "$@" ;;
  *) usage ;;
esac
