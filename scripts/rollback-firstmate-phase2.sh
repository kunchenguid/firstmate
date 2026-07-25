#!/usr/bin/env bash
# Roll back FirstMate Phase 2 overlay to a recorded backup.
# Usage: scripts/rollback-firstmate-phase2.sh [backup-dir] [--hard-git] [--stop-workers]
set -euo pipefail

FM_HOME="${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$FM_HOME"

BACKUP="${1:-}"
HARD_GIT=0
STOP_WORKERS=0
for arg in "$@"; do
  case "$arg" in
    --hard-git) HARD_GIT=1 ;;
    --stop-workers) STOP_WORKERS=1 ;;
    --help|-h)
      sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
  BACKUP=$(ls -1d backups/phase2-* 2>/dev/null | sort | tail -1 || true)
fi
if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
  echo "rollback: no backup directory found under backups/phase2-*" >&2
  exit 1
fi

echo "rollback: using $BACKUP"

systemctl --user stop firstmate-phase2-eventd.service 2>/dev/null || true
systemctl --user stop firstmate-phase2-watchdog.service 2>/dev/null || true

if [ "$STOP_WORKERS" -eq 1 ]; then
  echo "rollback: --stop-workers requested; refusing automated crew kills (manual teardown only)" >&2
  echo "  use: bin/fm-teardown.sh <task-id> after confirming dirty state" >&2
fi

if [ -f state/programme.db ]; then
  aside="state/programme.db.rolled-$(date +%s)"
  mv state/programme.db "$aside"
  echo "rollback: moved programme.db -> $aside"
  rm -f state/programme.db-wal state/programme.db-shm 2>/dev/null || true
fi

if [ -d "$BACKUP/config" ]; then
  mkdir -p config
  cp -a "$BACKUP/config/." config/
  echo "rollback: restored config/ from backup"
fi

if [ "$HARD_GIT" -eq 1 ]; then
  if [ ! -f "$BACKUP/COMMIT" ]; then
    echo "rollback: --hard-git requires $BACKUP/COMMIT" >&2
    exit 1
  fi
  commit=$(tr -d '[:space:]' < "$BACKUP/COMMIT")
  echo "rollback: HARD GIT checkout $commit (local Phase 2 commits may be orphaned)"
  git checkout "$commit" -- .
else
  echo "rollback: skipped git hard reset (pass --hard-git to restore tracked files to backup commit)"
fi

echo "rollback: complete. Verify with docs/FIRSTMATE-PHASE2-ROLLBACK.md"
