#!/usr/bin/env bash
# fm-sovereign-ledger-redundancy.sh - make, advance, and verify a sovereign-ledger replica.
#
# Usage:
#   fm-sovereign-ledger-redundancy.sh [--allow-same-volume-without-device-redundancy] snapshot <primary-ledger-dir> <replica-ledger-dir>
#   fm-sovereign-ledger-redundancy.sh [--allow-same-volume-without-device-redundancy] refresh <primary-ledger-dir> <replica-ledger-dir>
#   fm-sovereign-ledger-redundancy.sh [--allow-same-volume-without-device-redundancy] verify <primary-ledger-dir> <replica-ledger-dir>
#
# The default admission predicate requires different st_dev values, so a certified replica is on a different device.
# The named opt-out preserves same-volume operation while explicitly giving up device-level redundancy.
# Every public command enters through admit_pair before command-specific code can read, compare, execute, or write the pair.
# This script never admits, rewrites, repairs, or attributes a ruling.
set -euo pipefail

BUNDLE_MEMBER_COUNT=4
BUNDLE_ENTRIES=
ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY=no
ADMITTED_PRIMARY=
ADMITTED_REPLICA=
ADMITTED_PRIMARY_DEVICE=
ADMITTED_REPLICA_DEVICE=
ADMITTED_PRIMARY_DIRECTORY_IDENTITY=
ADMITTED_REPLICA_DIRECTORY_IDENTITY=
ADMITTED_PRIMARY_MEMBER_IDENTITIES=
ADMITTED_REPLICA_MEMBER_IDENTITIES=
CREATED_REPLICA=

die() {
  if [ -n "$CREATED_REPLICA" ]; then
    printf 'REFUSED: %s; partial replica retained without deletion: %s\n' "$*" "$CREATED_REPLICA" >&2
  else
    printf 'REFUSED: %s\n' "$*" >&2
  fi
  exit 1
}

usage() {
  sed -n '2,12{s/^# \{0,1\}//;p;}' "$0" >&2
  exit 2
}

canonical_dir() {
  [ -d "$1" ] || die "ledger directory does not exist: $1"
  (
    cd -- "$1"
    pwd -P
  )
}

bundle_manifest() {
  printf '%s\n' CONTRACT.md fm-sovereign-ledger.sh ledger.tsv tests.sh
}

collect_bundle_entries() {
  local dir=$1 entries required count
  # shellcheck disable=SC2016
  if ! entries=$(find "$dir" -mindepth 1 -maxdepth 1 -exec /bin/sh -c '
    for path do
      printf "%s\n" "${path##*/}"
    done
  ' sh {} + | LC_ALL=C sort); then
    die "could not enumerate ledger bundle: $dir"
  fi
  required=$(bundle_manifest)
  count=$(printf '%s\n' "$entries" | wc -l | tr -d '[:space:]')
  [ "$entries" = "$required" ] \
    || die "ledger bundle manifest differs from the exact required names: $dir"
  [ "$count" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "ledger bundle must contain exactly $BUNDLE_MEMBER_COUNT manifest members, found $count: $dir"
  BUNDLE_ENTRIES=$entries
}

require_bundle() {
  local dir=$1 entry checked=0
  collect_bundle_entries "$dir"
  while IFS= read -r entry; do
    [ -L "$dir/$entry" ] && die "ledger bundle contains a symlink: $dir/$entry"
    [ -f "$dir/$entry" ] || die "ledger bundle contains a non-regular file: $dir/$entry"
    checked=$((checked + 1))
  done <<< "$BUNDLE_ENTRIES"
  [ "$checked" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "ledger bundle manifest check read $checked of $BUNDLE_MEMBER_COUNT members: $dir"
  [ -x "$dir/fm-sovereign-ledger.sh" ] || die "ledger verifier is not executable: $dir/fm-sovereign-ledger.sh"
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

portable_device_identity() {
  local path=$1 identity
  if identity=$(stat -f '%d' "$path" 2>/dev/null); then
    :
  elif identity=$(stat -c '%d' "$path" 2>/dev/null); then
    :
  else
    return 1
  fi
  printf '%s\n' "$identity" | LC_ALL=C grep -Eq '^[0-9]+$' || return 1
  printf '%s\n' "$identity"
}

portable_directory_identity() {
  local path=$1 identity
  if identity=$(stat -L -f '%d:%i' "$path" 2>/dev/null); then
    :
  elif identity=$(stat -L -c '%d:%i' "$path" 2>/dev/null); then
    :
  else
    return 1
  fi
  printf '%s\n' "$identity" | LC_ALL=C grep -Eq '^[0-9]+:[0-9]+$' || return 1
  printf '%s\n' "$identity"
}

portable_member_identity() {
  portable_directory_identity "$1"
}

require_noncontained_pair() {
  local primary=$1 replica=$2
  [ "$primary" != "$replica" ] || die "primary and replica directories must differ"
  case "$primary/" in "$replica/"*) die "primary and replica directories must not contain one another" ;; esac
  case "$replica/" in "$primary/"*) die "primary and replica directories must not contain one another" ;; esac
}

admit_device_pair() {
  local primary=$1 replica=$2 primary_device replica_device
  primary_device=$(portable_device_identity "$primary") \
    || die "could not establish primary st_dev identity: $primary"
  replica_device=$(portable_device_identity "$replica") \
    || die "could not establish replica st_dev identity: $replica"
  if [ "$primary_device" = "$replica_device" ] \
    && [ "$ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY" != yes ]; then
    die "primary and replica must be on different devices (st_dev differs); use --allow-same-volume-without-device-redundancy only when explicitly waiving device redundancy"
  fi
  ADMITTED_PRIMARY_DEVICE=$primary_device
  ADMITTED_REPLICA_DEVICE=$replica_device
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

require_admitted_directory() {
  local label=$1 path=$2 expected=$3 canonical identity
  canonical=$(canonical_dir "$path")
  [ "$canonical" = "$path" ] || die "$label directory no longer resolves to its admitted path: $path"
  identity=$(portable_directory_identity "$path") \
    || die "could not re-establish $label directory identity: $path"
  [ "$identity" = "$expected" ] || die "$label directory changed after admission: $path"
}

admit_independent_bundle_members() {
  local primary=$1 replica=$2 entry primary_entry replica_entry identity
  local primary_identities= replica_identities= primary_identity replica_identity compared=0
  collect_bundle_entries "$primary"
  while IFS= read -r entry; do
    identity=$(portable_member_identity "$primary/$entry") \
      || die "could not establish primary bundle member identity: $primary/$entry"
    primary_identities="${primary_identities}${entry}\t${identity}\n"
    identity=$(portable_member_identity "$replica/$entry") \
      || die "could not establish replica bundle member identity: $replica/$entry"
    replica_identities="${replica_identities}${entry}\t${identity}\n"
  done <<< "$BUNDLE_ENTRIES"
  while IFS=$'\t' read -r primary_entry primary_identity; do
    while IFS=$'\t' read -r replica_entry replica_identity; do
      [ "$primary_identity" != "$replica_identity" ] \
        || die "replica $replica_entry shares storage with primary $primary_entry (device:inode), not an independent file"
      compared=$((compared + 1))
    done < <(printf '%b' "$replica_identities")
  done < <(printf '%b' "$primary_identities")
  [ "$compared" -eq $((BUNDLE_MEMBER_COUNT * BUNDLE_MEMBER_COUNT)) ] \
    || die "bundle member identity proof compared $compared of $((BUNDLE_MEMBER_COUNT * BUNDLE_MEMBER_COUNT)) required pairs"
  ADMITTED_PRIMARY_MEMBER_IDENTITIES=$(printf '%b' "$primary_identities")
  ADMITTED_REPLICA_MEMBER_IDENTITIES=$(printf '%b' "$replica_identities")
}

require_admitted_bundle_members() {
  local primary=$1 replica=$2 entry expected identity checked=0
  while IFS=$'\t' read -r entry expected; do
    identity=$(portable_member_identity "$primary/$entry") \
      || die "could not re-establish primary bundle member identity: $primary/$entry"
    [ "$identity" = "$expected" ] || die "primary bundle member changed after admission: $primary/$entry"
    checked=$((checked + 1))
  done <<< "$ADMITTED_PRIMARY_MEMBER_IDENTITIES"
  while IFS=$'\t' read -r entry expected; do
    identity=$(portable_member_identity "$replica/$entry") \
      || die "could not re-establish replica bundle member identity: $replica/$entry"
    [ "$identity" = "$expected" ] || die "replica bundle member changed after admission: $replica/$entry"
    checked=$((checked + 1))
  done <<< "$ADMITTED_REPLICA_MEMBER_IDENTITIES"
  [ "$checked" -eq $((BUNDLE_MEMBER_COUNT * 2)) ] \
    || die "admitted bundle member check read $checked of $((BUNDLE_MEMBER_COUNT * 2)) required identities"
}

admit_existing_pair() {
  local primary=$1 replica=$2 mode=$3
  require_noncontained_pair "$primary" "$replica"
  admit_device_pair "$primary" "$replica"
  require_bundle "$primary"
  require_bundle "$replica"
  admit_independent_bundle_members "$primary" "$replica"
  compare_files "$primary" "$replica" ledger.tsv
  verify_with_primary "$primary" "$primary"
  verify_with_primary "$primary" "$replica"
  case "$mode" in
    exact) compare_files "$primary" "$replica" ;;
    prefix) replica_is_prefix "$primary" "$replica" \
      || die "replica is not a verified byte-exact append-only prefix of primary" ;;
    inspect) ;;
    *) die "internal admission mode is invalid: $mode" ;;
  esac
  require_bundle "$primary"
  require_bundle "$replica"
  admit_device_pair "$primary" "$replica"
  admit_independent_bundle_members "$primary" "$replica"
  compare_files "$primary" "$replica" ledger.tsv
  case "$mode" in
    exact) compare_files "$primary" "$replica" ;;
    prefix) replica_is_prefix "$primary" "$replica" \
      || die "replica changed after prefix admission" ;;
  esac
  ADMITTED_PRIMARY_DIRECTORY_IDENTITY=$(portable_directory_identity "$primary") \
    || die "could not establish admitted primary directory identity: $primary"
  ADMITTED_REPLICA_DIRECTORY_IDENTITY=$(portable_directory_identity "$replica") \
    || die "could not establish admitted replica directory identity: $replica"
}

copy_file_exclusively() {
  local source=$1 destination=$2
  perl -MFcntl=O_WRONLY,O_CREAT,O_EXCL -e '
    use strict;
    use warnings;
    my ($source, $destination) = @ARGV;
    open my $input, "<", $source or die "$source: $!\n";
    binmode $input;
    my @source_stat = stat $input;
    local $/;
    my $content = <$input>;
    close $input or die "$source: $!\n";
    sysopen my $output, $destination, O_WRONLY | O_CREAT | O_EXCL, 0600
      or die "$destination: $!\n";
    binmode $output;
    my $offset = 0;
    while ($offset < length $content) {
      my $written = syswrite $output, $content, length($content) - $offset, $offset;
      die "$destination: $!\n" unless defined $written;
      $offset += $written;
    }
    chmod($source_stat[2] & 07777, $output) or die "$destination: $!\n";
    close $output or die "$destination: $!\n";
  ' "$source" "$destination" 2>/dev/null \
    || die "could not exclusively copy bundle member: $destination"
}

copy_bundle() {
  local primary=$1 replica=$2 entry copied=0 replica_identity
  replica_identity=$(portable_directory_identity "$replica") \
    || die "could not establish new replica directory identity: $replica"
  collect_bundle_entries "$primary"
  while IFS= read -r entry; do
    require_admitted_directory replica "$replica" "$replica_identity"
    copy_file_exclusively "$primary/$entry" "$replica/$entry"
    copied=$((copied + 1))
  done <<< "$BUNDLE_ENTRIES"
  [ "$copied" -eq "$BUNDLE_MEMBER_COUNT" ] \
    || die "bundle copy read $copied of $BUNDLE_MEMBER_COUNT required members"
}

admit_snapshot_destination() {
  local primary=$1 replica_input=$2 parent base replica parent_identity
  parent=$(dirname -- "$replica_input")
  [ -d "$parent" ] || die "replica parent directory does not exist: $parent"
  [ ! -L "$parent" ] || die "replica parent directory is symlinked: $parent"
  parent=$(canonical_dir "$parent")
  base=$(basename -- "$replica_input")
  case "$base" in ''|.|..) die "unsafe replica destination leaf: $replica_input" ;; esac
  replica="$parent/$base"
  require_noncontained_pair "$primary" "$replica"
  [ ! -e "$replica" ] && [ ! -L "$replica" ] \
    || die "replica destination already exists or is symlinked: $replica"
  admit_device_pair "$primary" "$parent"
  parent_identity=$(portable_directory_identity "$parent") \
    || die "could not establish replica parent directory identity before creation: $parent"
  require_admitted_directory "replica parent" "$parent" "$parent_identity"
  mkdir -- "$replica" || die "could not exclusively create replica destination: $replica"
  CREATED_REPLICA=$replica
  ADMITTED_REPLICA_DIRECTORY_IDENTITY=$(portable_directory_identity "$replica") \
    || die "could not establish new replica directory identity: $replica"
  copy_bundle "$primary" "$replica"
  admit_existing_pair "$primary" "$replica" exact
  ADMITTED_REPLICA=$replica
}

admit_pair() {
  local primary_input=$1 replica_input=$2 mode=$3 primary replica
  primary=$(canonical_dir "$primary_input")
  if [ "$mode" = snapshot ] && [ ! -e "$replica_input" ] && [ ! -L "$replica_input" ]; then
    require_bundle "$primary"
    verify_with_primary "$primary" "$primary"
    ADMITTED_PRIMARY=$primary
    admit_snapshot_destination "$primary" "$replica_input"
    return
  fi
  replica=$(canonical_dir "$replica_input")
  require_noncontained_pair "$primary" "$replica"
  require_bundle "$primary"
  verify_with_primary "$primary" "$primary"
  case "$mode" in
    snapshot) mode=exact ;;
  esac
  admit_existing_pair "$primary" "$replica" "$mode"
  ADMITTED_PRIMARY=$primary
  ADMITTED_REPLICA=$replica
}

copy_ledger_atomically() {
  local primary=$1 replica=$2 parent base tmp
  require_admitted_directory primary "$primary" "$ADMITTED_PRIMARY_DIRECTORY_IDENTITY"
  require_admitted_directory replica "$replica" "$ADMITTED_REPLICA_DIRECTORY_IDENTITY"
  require_admitted_bundle_members "$primary" "$replica"
  parent=$(dirname -- "$replica")
  base=$(basename -- "$replica")
  tmp=$(mktemp "$parent/.${base}.ledger.tsv.tmp.XXXXXX") \
    || die "could not create refresh staging file beside replica"
  if ! cp -p "$primary/ledger.tsv" "$tmp"; then
    rm -f -- "$tmp"
    die "could not stage primary ledger.tsv for refresh"
  fi
  if ! perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$tmp" "$replica/ledger.tsv"; then
    rm -f -- "$tmp"
    die "could not publish refreshed replica ledger.tsv"
  fi
}

cmd_snapshot() {
  admit_pair "$1" "$2" snapshot
  if [ -n "$CREATED_REPLICA" ]; then
    CREATED_REPLICA=
    printf 'SNAPSHOT PASS (replica created: %s)\n' "$ADMITTED_REPLICA"
  else
    printf 'SNAPSHOT PASS (replica already identical: %s)\n' "$ADMITTED_REPLICA"
  fi
}

cmd_refresh() {
  admit_pair "$1" "$2" prefix
  copy_ledger_atomically "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA"
  admit_pair "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA" exact
  printf 'REFRESH PASS (replica advanced to primary)\n'
}

cmd_verify() {
  admit_pair "$1" "$2" inspect
  if ! cmp -s "$ADMITTED_PRIMARY/ledger.tsv" "$ADMITTED_REPLICA/ledger.tsv"; then
    replica_is_prefix "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA" \
      && die "replica is a verified stale prefix; run refresh to advance it"
    die "replica ledger.tsv diverges from primary"
  fi
  admit_pair "$ADMITTED_PRIMARY" "$ADMITTED_REPLICA" exact
  if [ "$ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY" = yes ]; then
    printf 'REDUNDANCY VERIFY PASS (exact 4-member manifest byte-read; same-volume device redundancy explicitly waived; st_dev %s=%s)\n' "$ADMITTED_PRIMARY_DEVICE" "$ADMITTED_REPLICA_DEVICE"
  else
    printf 'REDUNDANCY VERIFY PASS (exact 4-member manifest byte-read; primary and replica st_dev identities disjoint: %s!=%s)\n' "$ADMITTED_PRIMARY_DEVICE" "$ADMITTED_REPLICA_DEVICE"
  fi
}

if [ "${1:-}" = --allow-same-volume-without-device-redundancy ]; then
  ALLOW_SAME_VOLUME_WITHOUT_DEVICE_REDUNDANCY=yes
  shift
fi

case "${1:-}" in
  snapshot) shift; [ "$#" -eq 2 ] || usage; cmd_snapshot "$@" ;;
  refresh) shift; [ "$#" -eq 2 ] || usage; cmd_refresh "$@" ;;
  verify) shift; [ "$#" -eq 2 ] || usage; cmd_verify "$@" ;;
  *) usage ;;
esac
