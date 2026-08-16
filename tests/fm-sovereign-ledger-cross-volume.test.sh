#!/usr/bin/env bash
# Prove the strict default accepts a genuine replica on a separately mounted volume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/bin/fm-sovereign-ledger-redundancy.sh"
FIXTURE="$ROOT/tests/fixtures/sovereign-ledger-redundancy"
TMP="$(mktemp -d)"
VOLUME_ROOT=
ATTACHED_VOLUME=no

cleanup() {
  if [ "$ATTACHED_VOLUME" = yes ]; then
    hdiutil detach "$VOLUME_ROOT" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
  if [ -n "$VOLUME_ROOT" ] && [ "$ATTACHED_VOLUME" = no ]; then
    rm -rf -- "$VOLUME_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

device_identity() {
  local identity
  if identity=$(stat -f '%d' "$1" 2>/dev/null); then
    :
  elif identity=$(stat -c '%d' "$1" 2>/dev/null); then
    :
  else
    return 1
  fi
  printf '%s\n' "$identity"
}

if [ -d /dev/shm ] && [ -w /dev/shm ] \
  && [ "$(device_identity /dev/shm)" != "$(device_identity "$TMP")" ]; then
  VOLUME_ROOT=$(mktemp -d /dev/shm/fm-ledger-volume.XXXXXX)
elif command -v hdiutil >/dev/null 2>&1; then
  VOLUME_ROOT="$TMP/ledger-volume"
  mkdir "$VOLUME_ROOT"
  hdiutil create -quiet -size 32m -fs APFS -volname fm-ledger-r5 "$TMP/ledger-volume.dmg"
  hdiutil attach -quiet -nobrowse -mountpoint "$VOLUME_ROOT" "$TMP/ledger-volume.dmg"
  ATTACHED_VOLUME=yes
else
  printf 'FAIL no writable separate volume is available for the strict acceptance proof\n' >&2
  exit 1
fi

PRIMARY="$TMP/primary"
REPLICA="$VOLUME_ROOT/replica"
mkdir "$PRIMARY"
cp "$FIXTURE/CONTRACT.md" "$PRIMARY/CONTRACT.md"
cp "$FIXTURE/fm-sovereign-ledger.sh" "$PRIMARY/fm-sovereign-ledger.sh"
cp "$FIXTURE/tests.sh" "$PRIMARY/tests.sh"
chmod +x "$PRIMARY/fm-sovereign-ledger.sh" "$PRIMARY/tests.sh"
: > "$PRIMARY/ledger.tsv"
for number in 1 2 3 4; do
  printf 'ruling-%s\t/source-%s\tZml4dHVyZQo=\n' "$number" "$number" >> "$PRIMARY/ledger.tsv"
done

PRIMARY_DEVICE=$(device_identity "$PRIMARY")
REPLICA_PARENT_DEVICE=$(device_identity "$VOLUME_ROOT")
[ "$PRIMARY_DEVICE" != "$REPLICA_PARENT_DEVICE" ] || {
  printf 'FAIL separate-volume fixture unexpectedly shares st_dev %s\n' "$PRIMARY_DEVICE" >&2
  exit 1
}
"$TOOL" snapshot "$PRIMARY" "$REPLICA" >/dev/null
"$TOOL" verify "$PRIMARY" "$REPLICA" >/dev/null
printf '2 passed, 0 failed (strict cross-volume snapshot and verify; st_dev %s!=%s)\n' "$PRIMARY_DEVICE" "$REPLICA_PARENT_DEVICE"
