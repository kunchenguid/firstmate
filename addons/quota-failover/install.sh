#!/usr/bin/env bash
# Install the quota-failover watcher for this user and register an exec shim to it as a home's quota-failover-watch
# check (a different check is backed up first). --all: the home and each local, unparked home its data/secondmates.md
# lists (a remote one is named and skipped); --list prints those homes and writes nothing. Idempotent.
# Usage: install.sh [--dry-run] [--all] [--list] <fm-home>
set -euo pipefail
DRY=0 ALL=0 LIST=0
while [ "$#" -gt 1 ]; do
  case $1 in --dry-run) DRY=1 ;; --all) ALL=1 ;; --list) LIST=1 ;; *) break ;; esac
  shift
done
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: install.sh [--dry-run] [--all] [--list] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-quota-failover
ID=quota-failover-watch
# The sibling add-on libs the watcher sources by its own path, copied beside it in the same layout.
LIBS="parked-homes/bin/fm-parked-homes-lib.sh account-pool/bin/fm-account-pool-lib.sh account-pool/bin/fm-pool-claude-env.sh"

# homes: "<name><TAB><dir>" for <fm-home> and, with --all, each active local secondmate home it lists.
homes() {
  local line name dir re='^- ([^[:space:]]+) - .*\((host:[^;]*;[[:space:]]*root:[^;]*;[[:space:]]*)?home: ([^;]*[^;[:space:]])[[:space:]]*;'
  printf 'main\t%s\n' "$FMH"
  [ "$ALL" -eq 1 ] && [ -f "$FMH/data/secondmates.md" ] || return 0
  # shellcheck source=parked-homes/bin/fm-parked-homes-lib.sh
  . "$SRC/parked-homes/bin/fm-parked-homes-lib.sh"
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    name=${BASH_REMATCH[1]} dir=${BASH_REMATCH[3]}
    if [ -n "${BASH_REMATCH[2]}" ]; then echo "skipped: $name: a remote home, install it on its host" >&2
    elif FM_HOME=$FMH fm_parked_home "$name"; then echo "skipped: $name: parked" >&2
    else printf '%s\t%s\n' "$name" "$dir"
    fi
  done <"$FMH/data/secondmates.md"
}

[ "$LIST" -eq 0 ] || { homes; exit 0; }
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/quota-failover/{quota-failover,check.sh} and the sibling libs it sources ($LIBS) -> $DEST"
else
  install -D -m 755 "$SRC/quota-failover/quota-failover" "$DEST/quota-failover/quota-failover"
  install -D -m 755 "$SRC/quota-failover/check.sh" "$DEST/quota-failover/check.sh"
  for lib in $LIBS; do install -D -m 644 "$SRC/$lib" "$DEST/$lib"; done
fi
fails=0
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/fm-check-register.sh" ] && [ -d "$home/state" ] || {
    echo "skipped: $name: $home has no bin/fm-check-register.sh or state/" >&2; fails=$((fails + 1)); continue; }
  home=$(cd "$home" && pwd -P)
  check=$home/state/$ID.check.sh
  shim=$(printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/quota-failover/check.sh" "$home")
  bak=
  [ ! -e "$check" ] || [ "$(cat "$check")" = "$shim" ] || bak=$check.bak-$ID-$(date +%s)
  if [ "$DRY" -eq 1 ]; then
    [ -z "$bak" ] || echo "would back up: $check -> $bak"
    echo "would write: $check: exec $DEST/quota-failover/check.sh $home"
    echo "would run: $home/bin/fm-check-register.sh $ID"
    continue
  fi
  [ -z "$bak" ] || { cp -p "$check" "$bak"; echo "backed up: $bak"; }
  printf '%s\n' "$shim" >"$check"
  chmod 700 "$check"
  # An FM_STATE_OVERRIDE in the caller env, even empty, would register away from the home's state.
  if env -u FM_STATE_OVERRIDE FM_HOME="$home" "$home/bin/fm-check-register.sh" "$ID" >/dev/null; then
    echo "installed: $name: $check -> $DEST/quota-failover/check.sh"
  else
    echo "failed: $name: $home/bin/fm-check-register.sh $ID refused the check" >&2; fails=$((fails + 1))
  fi
done < <(homes)
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
[ "$fails" -eq 0 ]
