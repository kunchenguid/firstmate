#!/usr/bin/env bash
# Native remote-agent selector for the established AIME provider adapter.
# New dispatches publish executor=remote-agent while retaining AIME's proven
# fm-aime-task-state.v1 lifecycle. Existing executor=cloud-worker records remain
# owned and readable directly by fm-cloud-research-aime.sh without migration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1-}" in
  dispatch) FM_AIME_EXECUTOR=remote-agent exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" "$@" ;;
  *) exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" "$@" ;;
esac
