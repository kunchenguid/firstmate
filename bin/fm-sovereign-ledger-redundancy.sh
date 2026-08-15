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
# verify fails loudly on a stale prefix, a divergence, symlinks, non-regular files, an incomplete layout, or any shared file identity.
# No replica-controlled code runs until all bundle bytes have been compared to the primary.
# This script never admits, rewrites, repairs, or attributes a ruling.
set -euo pipefail

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

bundle_entries() {
  find "$1" -mindepth 1 -maxdepth 1 -print | sed "s#^$1/##" | LC_ALL=C sort
}

require_bundle() {
  local dir=$1 entry
  [ -f "$dir/ledger.tsv" ] || die "ledger bundle is incomplete: missing $dir/ledger.tsv"
  [ -f "$dir/CONTRACT.md" ] || die "ledger bundle is incomplete: missing $dir/CONTRACT.md"
  [ -f "$dir/fm-sovereign-ledger.sh" ] || die "ledger bundle is incomplete: missing $dir/fm-sovereign-ledger.sh"
  [ -x "$dir/fm-sovereign-ledger.sh" ] || die "ledger verifier is not executable: $dir/fm-sovereign-ledger.sh"
  while IFS= read -r entry; do
    [ -L "$dir/$entry" ] && die "ledger bundle contains a symlink: $dir/$entry"
    [ -f "$dir/$entry" ] || die "ledger bundle contains a non-regular file: $dir/$entry"
  done < <(bundle_entries "$dir")
}

compare_layout() {
  local primary=$1 replica=$2
  diff -u <(bundle_entries "$primary") <(bundle_entries "$replica") >/dev/null \
    || die "replica bundle layout differs from primary"
}

compare_files() {
  local primary=$1 replica=$2 skip=${3:-} entry
  while IFS= read -r entry; do
    [ "$entry" = "$skip" ] && continue
    cmp -s "$primary/$entry" "$replica/$entry" \
      || die "replica differs from primary: $entry"
  done < <(bundle_entries "$primary")
}

file_lstat_identity() {
  stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1"
}

file_stat_identity() {
  stat -L -f '%d:%i' "$1" 2>/dev/null || stat -L -c '%d:%i' "$1"
}

require_independent_bundle_files() {
  local primary=$1 replica=$2 entry primary_lstat replica_lstat primary_stat replica_stat
  while IFS= read -r entry; do
    primary_lstat=$(file_lstat_identity "$primary/$entry")
    replica_lstat=$(file_lstat_identity "$replica/$entry")
    [ "$primary_lstat" != "$replica_lstat" ] \
      || die "replica $entry shares the primary lstat identity (device:inode), not a separate file"
    primary_stat=$(file_stat_identity "$primary/$entry")
    replica_stat=$(file_stat_identity "$replica/$entry")
    [ "$primary_stat" != "$replica_stat" ] \
      || die "replica $entry resolves to the primary object (device:inode), not a separate file"
  done < <(bundle_entries "$primary")
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
  local primary=$1 replica=$2 entry
  umask 077
  while IFS= read -r entry; do
    cp -p "$primary/$entry" "$replica/$entry"
  done < <(bundle_entries "$primary")
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
    [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
    verify_exact_pair "$primary" "$replica"
    printf 'SNAPSHOT PASS (replica already identical: %s)\n' "$replica"
    return
  fi
  require_bundle "$primary"
  verify_with_primary "$primary" "$primary"
  parent=$(dirname "$replica_input")
  base=$(basename "$replica_input")
  [ -d "$parent" ] || die "replica parent directory does not exist: $parent"
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
  [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
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
  [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
  preflight_pair "$primary" "$replica"
  if ! cmp -s "$primary/ledger.tsv" "$replica/ledger.tsv"; then
    verify_with_primary "$primary" "$primary"
    verify_with_primary "$primary" "$replica"
    replica_is_prefix "$primary" "$replica" \
      && die "replica is a verified stale prefix; run refresh to advance it"
    die "replica ledger.tsv diverges from primary"
  fi
  verify_exact_pair "$primary" "$replica"
  printf 'REDUNDANCY VERIFY PASS (bundle byte-identical; every member has distinct lstat and stat identities)\n'
}

case "${1:-}" in
  snapshot) shift; [ "$#" -eq 2 ] || usage; cmd_snapshot "$@" ;;
  refresh) shift; [ "$#" -eq 2 ] || usage; cmd_refresh "$@" ;;
  verify) shift; [ "$#" -eq 2 ] || usage; cmd_verify "$@" ;;
  *) usage ;;
esac
