#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-sandbox-bridge)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR"
PORTABLE_BIN="$TMP_ROOT/portable-bin"
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
mkdir -p "$PORTABLE_BIN"
cat > "$PORTABLE_BIN/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = -- ] && exit 97
done
exec "$REAL_MV" "\$@"
SH
cat > "$PORTABLE_BIN/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = -- ] && exit 97
done
exec "$REAL_RM" "\$@"
SH
chmod 700 "$PORTABLE_BIN/mv" "$PORTABLE_BIN/rm"

cat > "$STATE_DIR/bogus.meta" <<EOF
window=tmux:bogus
placement=bogus
EOF

(
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  if watch_sync_sandbox_bridges; then
    exit 1
  fi
  [ "$WATCH_SANDBOX_BRIDGE_TASK" = bogus ]
) || fail 'unknown placement metadata was silently skipped'
pass 'unknown placement metadata produces an actionable bridge failure'

rm -f -- "$STATE_DIR/bogus.meta"
cat > "$STATE_DIR/host.meta" <<EOF
window=tmux:host
placement=host
EOF
(
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  watch_sync_sandbox_bridges
) || fail 'host metadata was changed by unknown placement handling'
pass 'host placement remains a silent no-op for bridge synchronization'

(
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  fm_spawn_cleanup_record_write "$STATE_DIR" cleanup-task \
    'endpoint_cleanup=1' 'endpoint_backend=tmux' 'endpoint_target=@cleanup' || exit 1
  if watch_spawn_cleanup_records; then
    exit 1
  fi
  [ "$WATCH_SPAWN_CLEANUP_TASK" = cleanup-task ]
) || fail 'durable unpublished cleanup was not surfaced by the watcher'
pass 'durable unpublished cleanup records produce an actionable watcher candidate'

(
  PATH="$PORTABLE_BIN:$PATH"
  export PATH
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-watch.sh disable=SC1091
  . "$ROOT/bin/fm-watch.sh"
  fm_spawn_cleanup_record_write "$STATE_DIR" portable-task \
    'endpoint_cleanup=1' 'endpoint_backend=tmux' 'endpoint_target=@portable' || exit 1
  [ -f "$STATE_DIR/.spawn-cleanup/portable-task.record" ] || exit 1
  fm_spawn_cleanup_record_remove "$STATE_DIR" portable-task || exit 1
  [ ! -e "$STATE_DIR/.spawn-cleanup/portable-task.record" ] || exit 1
  if fm_spawn_cleanup_record_write "$STATE_DIR" newline-task $'endpoint_target=one\ninjected=1'; then
    exit 1
  fi
  if fm_spawn_cleanup_record_write "$STATE_DIR" carriage-task $'endpoint_target=one\rinjected=1'; then
    exit 1
  fi
  if fm_spawn_cleanup_record_write "$STATE_DIR" tab-task $'endpoint_target=one\tinjected=1'; then
    exit 1
  fi
  if fm_spawn_cleanup_record_write "$STATE_DIR" control-task $'endpoint_target=one\vinjected=1'; then
    exit 1
  fi
  if fm_spawn_cleanup_record_write "$STATE_DIR" duplicate-task \
    'endpoint_cleanup=1' 'endpoint_cleanup=0'; then
    exit 1
  fi
  if fm_spawn_cleanup_record_write "$STATE_DIR" malformed-task 'endpoint_cleanup'; then
    exit 1
  fi
  [ ! -e "$STATE_DIR/.spawn-cleanup/newline-task.record" ] || exit 1
  [ ! -e "$STATE_DIR/.spawn-cleanup/duplicate-task.record" ] || exit 1
) || fail 'cleanup journals accepted unsafe or duplicate fields, or used GNU-only separators'
pass 'cleanup journals reject controls and duplicates with BSD-safe publication'

echo 'ALL TESTS PASSED'
