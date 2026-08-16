#!/usr/bin/env bash
# Prove the strict default accepts a genuine replica on a separately mounted volume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/bin/fm-sovereign-ledger-redundancy.sh"
FIXTURE="$ROOT/tests/fixtures/sovereign-ledger-redundancy"
TMP="$(mktemp -d)"
VOLUME_ROOT=
ATTACHED_VOLUME=no

cleanup_fixture() {
  local scratch=$1 volume_root=$2 attached=$3 hdiutil_command=$4
  if [ "$attached" = yes ]; then
    if ! "$hdiutil_command" detach "$volume_root" >/dev/null 2>&1; then
      printf 'FAIL could not detach fixture volume; retained scratch and image at %s\n' "$scratch" >&2
      return 1
    fi
    attached=no
  fi
  rm -rf -- "$scratch"
  if [ -n "$volume_root" ] && [ "$attached" = no ] && [[ "$volume_root" != "$scratch"/* ]]; then
    rm -rf -- "$volume_root"
  fi
}

finish() {
  local status=$?
  if ! cleanup_fixture "$TMP" "$VOLUME_ROOT" "$ATTACHED_VOLUME" hdiutil; then
    status=1
  fi
  trap - EXIT HUP INT TERM
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

FAKE_HDIUTIL="$TMP/fake-hdiutil"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf '%s\n' \"\$*\" >> \"\$CLEANUP_HDIUTIL_LOG\"" \
  "exit \"\$CLEANUP_HDIUTIL_STATUS\"" > "$FAKE_HDIUTIL"
chmod +x "$FAKE_HDIUTIL"
export CLEANUP_HDIUTIL_LOG CLEANUP_HDIUTIL_STATUS

CLEANUP_FAILURE="$TMP/cleanup-failure"
CLEANUP_FAILURE_VOLUME="$CLEANUP_FAILURE/volume"
CLEANUP_FAILURE_LOG="$TMP/cleanup-failure.log"
CLEANUP_FAILURE_DIAGNOSTIC="$TMP/cleanup-failure.diagnostic"
mkdir -p "$CLEANUP_FAILURE_VOLUME/replica"
: > "$CLEANUP_FAILURE/ledger-volume.dmg"
: > "$CLEANUP_FAILURE_VOLUME/replica/ledger.tsv"
if CLEANUP_HDIUTIL_LOG="$CLEANUP_FAILURE_LOG" CLEANUP_HDIUTIL_STATUS=1 \
  cleanup_fixture "$CLEANUP_FAILURE" "$CLEANUP_FAILURE_VOLUME" yes "$FAKE_HDIUTIL" 2> "$CLEANUP_FAILURE_DIAGNOSTIC"; then
  printf 'FAIL cleanup accepted a failed fixture-volume detach\n' >&2
  exit 1
fi
[ "$(cat "$CLEANUP_FAILURE_LOG")" = "detach $CLEANUP_FAILURE_VOLUME" ] \
  && grep -Fq 'retained scratch and image' "$CLEANUP_FAILURE_DIAGNOSTIC" \
  && [ -f "$CLEANUP_FAILURE/ledger-volume.dmg" ] \
  && [ -f "$CLEANUP_FAILURE_VOLUME/replica/ledger.tsv" ] || {
  printf 'FAIL failed detach did not retain the fixture scratch, image, and mounted-path contents\n' >&2
  exit 1
}
rm -rf -- "$CLEANUP_FAILURE"

CLEANUP_SUCCESS="$TMP/cleanup-success"
CLEANUP_SUCCESS_VOLUME="$CLEANUP_SUCCESS/volume"
CLEANUP_SUCCESS_LOG="$TMP/cleanup-success.log"
mkdir -p "$CLEANUP_SUCCESS_VOLUME/replica"
: > "$CLEANUP_SUCCESS/ledger-volume.dmg"
CLEANUP_HDIUTIL_LOG="$CLEANUP_SUCCESS_LOG" CLEANUP_HDIUTIL_STATUS=0 \
  cleanup_fixture "$CLEANUP_SUCCESS" "$CLEANUP_SUCCESS_VOLUME" yes "$FAKE_HDIUTIL"
[ "$(cat "$CLEANUP_SUCCESS_LOG")" = "detach $CLEANUP_SUCCESS_VOLUME" ] \
  && [ ! -e "$CLEANUP_SUCCESS" ] || {
  printf 'FAIL successful detach did not remove the fixture scratch and image\n' >&2
  exit 1
}

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
  ATTACHED_VOLUME=yes
  hdiutil attach -quiet -nobrowse -mountpoint "$VOLUME_ROOT" "$TMP/ledger-volume.dmg"
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
