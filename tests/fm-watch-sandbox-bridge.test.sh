#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-sandbox-bridge)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE"

cat > "$STATE/bogus.meta" <<EOF
window=tmux:bogus
placement=bogus
EOF

(
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  if watch_sync_sandbox_bridges; then
    exit 1
  fi
  [ "$WATCH_SANDBOX_BRIDGE_TASK" = bogus ]
) || fail 'unknown placement metadata was silently skipped'
pass 'unknown placement metadata produces an actionable bridge failure'

rm -f -- "$STATE/bogus.meta"
cat > "$STATE/host.meta" <<EOF
window=tmux:host
placement=host
EOF
(
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  watch_sync_sandbox_bridges
) || fail 'host metadata was changed by unknown placement handling'
pass 'host placement remains a silent no-op for bridge synchronization'

(
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  fm_spawn_cleanup_record_write "$STATE" cleanup-task \
    'endpoint_cleanup=1' 'endpoint_backend=tmux' 'endpoint_target=@cleanup' || exit 1
  if watch_spawn_cleanup_records; then
    exit 1
  fi
  [ "$WATCH_SPAWN_CLEANUP_TASK" = cleanup-task ]
) || fail 'durable unpublished cleanup was not surfaced by the watcher'
pass 'durable unpublished cleanup records produce an actionable watcher candidate'

echo 'ALL TESTS PASSED'
