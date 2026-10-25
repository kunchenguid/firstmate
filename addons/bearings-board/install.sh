#!/usr/bin/env bash
# Wire the Bearings board wrapper into one Firstmate home: a launcher that runs the
# checkout's board. A home hook at config/bearings-board-command
# is pointed at the launcher only when it exists; otherwise install prints the command.
# The hook keeps the file, mode and links it had: install saves its content beside it and
# rewrites that content in place through whatever the hook is. A hook that already names
# the launcher is left as it is and keeps the backup recorded by the install that wrote
# it, so uninstall restores the operator's content. The record's backup field is the
# ownership mark: install wrote the hook exactly when it is set.
# The launcher and the install record are written before the hook is repointed, so a
# failed install leaves the home's board command working and removable.
# Idempotent: rerun it to update. Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/fm-bearings-board.sh" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
LAUNCHER="$FMH/state/bearings-board-thin"
HOOK="$FMH/config/bearings-board-command"
RECORD="$FMH/state/bearings-board-thin.install"
STAMP=$(date +%s)

hook_state=- hook_backup=- hook_write=0
prev_hook=- prev_backup=-
if [ -f "$RECORD" ]; then
  prev_hook=$(sed -n 's/^hook=//p' "$RECORD")
  prev_backup=$(sed -n 's/^backup=//p' "$RECORD")
fi
if [ -e "$HOOK" ]; then
  hook_state=$HOOK
  if [ "$(cat "$HOOK")" = "$LAUNCHER" ]; then
    if [ "$prev_hook" = "$HOOK" ] && [ "$prev_backup" != - ]; then
      hook_backup=$prev_backup
    fi
  elif ! grep -qF -- "$LAUNCHER" "$HOOK"; then
    hook_backup="$HOOK.bak-bearings-board-thin-$STAMP"
    hook_write=1
  fi
fi

if [ "$DRY" -eq 1 ]; then
  echo "dry run: nothing written; would write $LAUNCHER and $RECORD"
  if [ "$hook_state" = - ]; then
    echo "no home hook at $HOOK: set this home's board command to $LAUNCHER"
  elif [ "$hook_write" -eq 0 ]; then
    echo "would leave $HOOK alone: it already names $LAUNCHER"
  else
    echo "would back up $HOOK to $hook_backup, then point it at $LAUNCHER"
  fi
  exit 0
fi

mkdir -p "$FMH/state"
printf '#!/usr/bin/env bash\nexec env FM_CODE_ROOT=%q FM_HOME=%q %q "$@"\n' "$FMH" "$FMH" "$SRC/bin/fm-bearings-board.sh" > "$LAUNCHER.tmp-$STAMP"
chmod 700 "$LAUNCHER.tmp-$STAMP" && mv "$LAUNCHER.tmp-$STAMP" "$LAUNCHER"
printf 'launcher=%s\nhook=%s\nbackup=%s\n' "$LAUNCHER" "$hook_state" "$hook_backup" > "$RECORD"
echo "installed: $LAUNCHER"

if [ "$hook_state" = - ]; then
  echo "no home hook at $HOOK: set this home's board command to $LAUNCHER"
  exit 0
fi
if [ "$hook_write" -eq 0 ]; then
  echo "left $HOOK alone: it already names $LAUNCHER"
  exit 0
fi
cp -p "$HOOK" "$hook_backup"
printf '%s\n' "$LAUNCHER" > "$HOOK"
echo "pointed $HOOK at $LAUNCHER (backup $hook_backup)"
