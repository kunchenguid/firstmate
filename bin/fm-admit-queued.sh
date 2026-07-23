#!/usr/bin/env bash
# Admit durable queued spawns in FIFO order while resource policy permits.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUEUE="$STATE/resource-queue"

[ -d "$QUEUE" ] || exit 0
for item in $(find "$QUEUE" -maxdepth 1 -type f -name '*.queue' -print | sort); do
  id=${item##*/}
  id=${id%.queue}
  argv=$(sed -n 's/^argv=//p' "$item")
  [ -n "$argv" ] || continue
  running="$item.running"
  mv "$item" "$running"
  if FM_RESOURCE_FROM_QUEUE=1 FM_QUEUE_ARGV="$argv" FM_QUEUE_SPAWN="$FM_ROOT/bin/fm-spawn.sh" \
    bash -c 'eval "set -- $FM_QUEUE_ARGV"; exec "$FM_QUEUE_SPAWN" "$@"'; then
    rm -f "$running"
    echo "admitted $id"
  else
    status=$?
    if [ "$status" -eq 75 ]; then
      mv "$running" "$item"
      break
    fi
    mv "$running" "$item.failed"
    echo "error: queued spawn $id failed with status $status" >&2
  fi
done
