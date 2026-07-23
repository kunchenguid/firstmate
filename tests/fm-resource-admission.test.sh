#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
# shellcheck source=bin/fm-resource-lib.sh
. "$ROOT/bin/fm-resource-lib.sh"

state="$TMP_ROOT/state"
config="$TMP_ROOT/config"
mkdir -p "$state" "$config"

write_heavy() {
  printf 'kind=ship\nresource_class=heavy\n' > "$state/$1.meta"
}

fm_resource_admit "$state" "$config" heavy
write_heavy one
write_heavy two
write_heavy three

if fm_resource_admit "$state" "$config" heavy; then
  echo "FAIL: fourth heavy crew was admitted without a headroom probe" >&2
  exit 1
fi

printf '#!/bin/sh\nexit 0\n' > "$config/resource-admission-probe"
chmod +x "$config/resource-admission-probe"
fm_resource_admit "$state" "$config" heavy

write_heavy four
if fm_resource_admit "$state" "$config" heavy; then
  echo "FAIL: fifth heavy crew was admitted" >&2
  exit 1
fi

fm_resource_admit "$state" "$config" medium
fm_resource_queue_write "$state" queued task-id "/path with spaces" --resource-class heavy
grep -q '^argv=' "$state/resource-queue/queued.queue"

echo "PASS: resource admission guarantees three, probes the fourth, caps at four, and queues durably"
