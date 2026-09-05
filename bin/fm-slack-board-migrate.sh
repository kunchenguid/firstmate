#!/usr/bin/env bash
# fm-slack-board-migrate.sh - lazy, idempotent, no-network migration of the
# Slack board identity, daily state, and recovery journal out of the task-record
# namespace. See fms_board_layout_assert for the phase-aware coherent-layout
# validator that encodes the production writer's actual phase transitions.
#
# This is the deployment migration owner, invoked by bootstrap before its
# first state/*.meta scan and by the `board` command under the board lock
# before any Slack API call. Never calls Slack and never requires Slack
# credentials; it sources fm-slack-lib.sh only for the shared value predicates
# (fms_channel_id_valid, fms_message_ts_valid) so local acceptance cannot
# diverge from chat.update validation.
#
# Contract: a complete legacy board is renamed atomically to state/slack-board/;
# an already-valid new path is a no-op; a fresh home (neither path) is a no-op.
# Any partial, ambiguous, malformed, wrong-mode, non-regular, or both-paths
# layout, any impossible or conflicting journal/identity/state combination,
# or a move failure refuses with nonzero status, zero network calls, and
# unchanged bytes. Only the absence of both directories is a fresh-create
# state. Exit 0 on success/idempotent no-op, 1 on any refusal.
#
# This file is executed, never sourced.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

BOARD_DIR="$STATE/slack-board"
BOARD_DIR_LEGACY="$STATE/slack-board.meta"
BOARD_LOCK="$STATE/.slack-board.lock"
BOARD_SNAPSHOTS="$STATE/slack-board-snapshots"
LOCK_HELD=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

board_migrate_run() {
  fms_board_store_assert
}

if [ "${1:-}" = "--lock-held" ]; then
  LOCK_HELD=1
elif [ -n "${1:-}" ]; then
  die "usage: fm-slack-board-migrate.sh [--lock-held]"
fi

# A fresh home with no state directory has nothing to migrate and no lock to take.
if [ ! -d "$STATE" ]; then
  exit 0
fi

if [ "$LOCK_HELD" -eq 0 ]; then
  fm_lock_acquire_wait "$BOARD_LOCK" || die "could not acquire board lock"
  trap 'fm_lock_release "$BOARD_LOCK"' EXIT
fi

board_migrate_run
