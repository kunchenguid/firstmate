#!/usr/bin/env bash
# fm-sovereign-ledger-redundancy.sh - make and verify one local replica of a sovereign ledger bundle.
#
# Usage:
#   fm-sovereign-ledger-redundancy.sh snapshot <primary-ledger-dir> <replica-ledger-dir>
#   fm-sovereign-ledger-redundancy.sh verify <primary-ledger-dir> <replica-ledger-dir>
#
# A ledger bundle is ledger.tsv, CONTRACT.md, and fm-sovereign-ledger.sh.
# snapshot verifies the primary through its own ledger verifier before it copies it.
# It creates a missing replica or accepts an already-identical one.
# It refuses a divergent existing replica instead of repairing or overwriting it.
# verify runs each bundle's ledger verifier, compares every protected file byte-for-byte, and rejects a hard-linked ledger.tsv.
# This script never admits, rewrites, repairs, or attributes a ruling.
set -euo pipefail

die() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,10{s/^# \{0,1\}//;p;}' "$0" >&2
  exit 2
}

canonical_dir() {
  [ -d "$1" ] || die "ledger directory does not exist: $1"
  (
    cd "$1"
    pwd -P
  )
}

create_replica_dir() {
  local dir=$1
  [ -e "$dir" ] && [ ! -d "$dir" ] && die "replica path is not a directory: $dir"
  mkdir -p "$dir"
  canonical_dir "$dir"
}

require_bundle() {
  local dir=$1 name
  for name in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh; do
    [ -f "$dir/$name" ] || die "ledger bundle is incomplete: missing $dir/$name"
  done
  [ -x "$dir/fm-sovereign-ledger.sh" ] || die "ledger verifier is not executable: $dir/fm-sovereign-ledger.sh"
}

verify_ledger() {
  local dir=$1
  LEDGER_DIR="$dir" "$dir/fm-sovereign-ledger.sh" verify >/dev/null || die "ledger verifier rejected $dir/ledger.tsv"
}

compare_file() {
  local primary=$1 replica=$2 name=$3
  cmp -s "$primary/$name" "$replica/$name" || die "replica differs from primary: $name"
}

file_identity() {
  stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1"
}

require_independent_ledger_file() {
  local primary=$1 replica=$2
  [ "$(file_identity "$primary/ledger.tsv")" != "$(file_identity "$replica/ledger.tsv")" ] || die "replica ledger.tsv is hard-linked to the primary, not a second copy"
}

verify_bundle() {
  local primary=$1 replica=$2 name
  require_bundle "$primary"
  require_bundle "$replica"
  verify_ledger "$primary"
  verify_ledger "$replica"
  for name in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh; do
    compare_file "$primary" "$replica" "$name"
  done
  require_independent_ledger_file "$primary" "$replica"
}

copy_bundle() {
  local primary=$1 replica=$2 name tmp
  umask 077
  for name in ledger.tsv CONTRACT.md fm-sovereign-ledger.sh; do
    tmp="$replica/.${name}.tmp.$$"
    cp "$primary/$name" "$tmp"
    mv "$tmp" "$replica/$name"
  done
}

cmd_snapshot() {
  local primary replica
  primary=$(canonical_dir "${1:?primary ledger directory}")
  replica=$(create_replica_dir "${2:?replica ledger directory}")
  [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
  require_bundle "$primary"
  verify_ledger "$primary"
  if [ -e "$replica/ledger.tsv" ] || [ -e "$replica/CONTRACT.md" ] || [ -e "$replica/fm-sovereign-ledger.sh" ]; then
    verify_bundle "$primary" "$replica"
    printf 'SNAPSHOT PASS (replica already identical: %s)\n' "$replica"
    return
  fi
  copy_bundle "$primary" "$replica"
  verify_bundle "$primary" "$replica"
  printf 'SNAPSHOT PASS (replica created: %s)\n' "$replica"
}

cmd_verify() {
  local primary replica
  primary=$(canonical_dir "${1:?primary ledger directory}")
  replica=$(canonical_dir "${2:?replica ledger directory}")
  [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
  verify_bundle "$primary" "$replica"
  printf 'REDUNDANCY VERIFY PASS (bundle identical and independently stored)\n'
}

case "${1:-}" in
  snapshot) shift; cmd_snapshot "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) usage ;;
esac
