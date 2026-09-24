#!/usr/bin/env bash
# fm-context-handoff-receipt.sh - confirm receipt of one secondmate relaunch
# handoff after the replacement has read it and is ready to resume.
#
# Usage: fm-context-handoff-receipt.sh <receipt-path> <task-id> <relaunch-tx> <handoff-sha256>
#
# The relaunch control plane places this exact command in the replacement-only
# instructions and retains every full context copy until this bounded receipt
# arrives. The receipt contains identifiers and a hash, never context content.
set -eu

usage() {
  sed -n '2,10{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 4 ] || { usage >&2; exit 2; }

receipt=$1
id=$2
tx=$3
handoff_sha256=$4

case "$receipt" in
  /*) ;;
  *) die "receipt path must be absolute" ;;
esac
case "$id" in
  ''|*[!A-Za-z0-9._-]*) die "invalid task id: $id" ;;
esac
case "$tx" in
  ''|*[!A-Za-z0-9._-]*) die "invalid relaunch transaction: $tx" ;;
esac
case "$handoff_sha256" in
  *[!0-9a-f]*|'') die "handoff SHA-256 must be exactly 64 lowercase hexadecimal characters" ;;
esac
[ "${#handoff_sha256}" -eq 64 ] \
  || die "handoff SHA-256 must be exactly 64 lowercase hexadecimal characters"
[ "${receipt##*/}" = "$id.control-relaunch.receipt-$tx" ] \
  || die "receipt path does not match the task and relaunch transaction"
parent=${receipt%/*}
[ -d "$parent" ] && [ ! -L "$parent" ] \
  || die "receipt directory is unavailable or unsafe: $parent"
if [ -e "$receipt" ] || [ -L "$receipt" ]; then
  [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    || die "existing receipt is not a safe regular file: $receipt"
fi

tmp=$(mktemp "$parent/.$id.control-relaunch.receipt.XXXXXX") \
  || die "could not stage context-handoff receipt"
trap 'rm -f -- "$tmp" 2>/dev/null || true' EXIT
if ! (umask 077; {
  printf 'v1\n'
  printf 'task=%s\n' "$id"
  printf 'relaunch_tx=%s\n' "$tx"
  printf 'handoff_sha256=%s\n' "$handoff_sha256"
  printf 'confirmation=received-and-resumed\n'
} > "$tmp"); then
  die "could not stage context-handoff receipt"
fi
if [ -e "$receipt" ] || [ -L "$receipt" ]; then
  cmp -s "$tmp" "$receipt" \
    || die "existing receipt does not match this context handoff"
  exit 0
fi
mv "$tmp" "$receipt" || die "could not publish context-handoff receipt"
trap - EXIT
printf 'context-handoff-received: %s\n' "$id"
