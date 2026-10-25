#!/usr/bin/env bash
# Remove git-identity files and its home launch shim. Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo 'usage: uninstall.sh [--dry-run] <fm-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P); DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-git-identity; HOOK=$FMH/config/launch-env-hook
SHIM=$(printf '#!/usr/bin/env bash\nexec %q env-file "$@"\n' "$DEST/git-identity")
HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc sendemail-validate'
if [ -e "$HOOK" ] && [ "$(cat "$HOOK")" = "$SHIM" ]; then
  backup=
  for b in "$HOOK".bak-git-identity-*; do [ -e "$b" ] || continue; backup=$b; done
  if [ "$DRY" -eq 1 ]; then [ -z "$backup" ] && echo "would remove: $HOOK" || echo "would restore: $backup -> $HOOK"; else
    if [ -n "$backup" ]; then mv -f "$backup" "$HOOK"; else rm -f -- "$HOOK"; fi
  fi
fi
for name in $HOOKS; do f=$DEST/hooks/$name; [ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }; done
[ ! -e "$DEST/git-identity" ] || { echo "remove: $DEST/git-identity"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/git-identity"; }
if [ -e "$DEST/identity.gitconfig" ]; then
  echo "remove: $DEST/identity.gitconfig"
  echo 'prior git identity values are not known and cannot be restored'
  [ "$DRY" -eq 1 ] || rm -f -- "$DEST/identity.gitconfig"
fi
[ "$DRY" -eq 1 ] || { rmdir "$DEST/hooks" 2>/dev/null || true; rmdir "$DEST" 2>/dev/null || true; }
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
