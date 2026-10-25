#!/usr/bin/env bash
# Remove what install.sh added to one Firstmate home, and nothing else: the install
# record and the launcher once nothing can still name it. The home hook gets its saved
# content back in place, keeping its file, mode and links; a hook that was gone when
# install ran, or that install never wrote and has since been edited, is left alone,
# and the launcher is kept whenever the home's board command may still name it.
# Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: uninstall.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
RECORD="$FMH/state/bearings-board-thin.install"
[ -f "$RECORD" ] || { echo "nothing installed in $FMH"; exit 0; }
field() { sed -n "s/^$1=//p" "$RECORD"; }
LAUNCHER=$(field launcher)
HOOK=$(field hook)
BACKUP=$(field backup)

kept=0
if [ "$HOOK" != - ] && [ -f "$HOOK" ] && [ "$(cat "$HOOK")" = "$LAUNCHER" ] && [ "$BACKUP" != - ]; then
  if [ -f "$BACKUP" ]; then
    [ "$DRY" -eq 1 ] || { cat "$BACKUP" > "$HOOK" && rm -f -- "$BACKUP"; }
    echo "restored $HOOK from $BACKUP"
  else
    [ "$DRY" -eq 1 ] || rm -f -- "$HOOK"
    echo "removed $HOOK: install had replaced it and that backup is gone"
  fi
else
  kept=1
  if [ "$HOOK" = - ]; then
    echo "no home hook was installed"
  elif [ "$BACKUP" = - ]; then
    echo "left $HOOK alone: install did not write it"
  else
    echo "left $HOOK alone: it changed since install"
  fi
  echo "kept $LAUNCHER: the home's board command may still name it; repoint that command, then delete the launcher"
fi

if [ "$DRY" -eq 1 ]; then
  echo "dry run: nothing removed; would remove $RECORD"
  [ "$kept" -eq 1 ] || echo "would remove $LAUNCHER"
  exit 0
fi
rm -f -- "$RECORD"
[ "$kept" -eq 1 ] || rm -f -- "$LAUNCHER"
echo "uninstalled from $FMH"
