#!/usr/bin/env bash
# Non-T3 inbox steering retains the recorded metadata's activity verdict,
# including partial records that still identify a terminal but lack a target.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-meta)
mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/config"

FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
  FM_BUSY_REGEX=BUSYTOKEN bash -eu -c '
  . "$1/bin/fm-watch.sh"
  meta="$STATE/worker.meta"
  printf "terminal=lab:fm-worker\nharness=grok\nkind=ship\n" > "$meta"

  verdict=$(fm_busy_classify_meta "$meta" worker "$STATE" "BUSYTOKEN active")
  [ "$verdict" = "unknown no-target" ]
  # The terminal and rendered busy token alone would classify busy.
  fm_busy_is_busy tmux lab:fm-worker grok worker "$STATE" "BUSYTOKEN active"
  if inbox_steer_busy lab:fm-worker tmux worker "BUSYTOKEN active"; then
    echo "missing metadata target incorrectly deferred non-T3 steering" >&2
    exit 1
  fi

  printf "window=lab:fm-worker\n" >> "$meta"
  inbox_steer_busy lab:fm-worker tmux worker "BUSYTOKEN active"
  if inbox_steer_busy lab:fm-worker tmux worker "quiet output"; then
    echo "idle non-T3 metadata incorrectly deferred steering" >&2
    exit 1
  fi
' _ "$ROOT"

pass "non-T3 inbox guard preserves no-target uncertainty and recorded busy/idle verdicts"
