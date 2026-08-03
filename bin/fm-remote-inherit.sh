#!/usr/bin/env bash
# Apply one primary-authoritative inherited item inside the selected remote home.
#
# Usage:
#   fm-remote-inherit.sh put <allowlisted-relative-path> < stdin
#   fm-remote-inherit.sh absent <allowlisted-relative-path>
#
# Only the inherited-material allowlist is writable or removable. Writes are
# atomic ordinary-file replacements. Divergent data/captain-shared.md bytes are
# quarantined before replacement or removal and its converged copy is read-only.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_BYTES=1048576

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
file_link_count() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
allowed() {
  case "$1" in
    config/crew-dispatch.json|config/crew-harness|config/backlog-backend|config/backend|config/herdr-presentation-spaces|config/startup-memory-budget|data/captain-shared.md) return 0 ;;
    *) return 1 ;;
  esac
}

[ "$#" -eq 2 ] || usage
COMMAND=$1
REL=$2
allowed "$REL" || die "path is not inherited material: $REL"
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
PARENT="$HOME_REAL/$(dirname "$REL")"
[ ! -L "$PARENT" ] || die "inherited destination parent is a symlink"
mkdir -p "$PARENT" || die "cannot create inherited destination parent"
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" && pwd -P)
case "$PARENT_REAL" in "$HOME_REAL/config"|"$HOME_REAL/data") ;; *) die "inherited destination escapes FM_HOME" ;; esac
DEST="$PARENT_REAL/$(basename "$REL")"
[ ! -L "$DEST" ] || die "inherited destination is a symlink"
if [ -e "$DEST" ]; then
  [ -f "$DEST" ] || die "inherited destination is not a regular file"
  [ "$(file_link_count "$DEST")" = 1 ] || die "inherited destination is hardlinked"
fi

quarantine_shared() {
  local reason=$1 quarantine stamp base n=0
  [ "$REL" = data/captain-shared.md ] && [ -f "$DEST" ] || return 0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$HOME_REAL/data/captain-shared.md.remote-quarantine-$stamp-$$"
  quarantine=$base
  while [ -e "$quarantine" ] || [ -L "$quarantine" ]; do
    n=$((n + 1))
    quarantine="$base.$n"
  done
  cp -p -- "$DEST" "$quarantine" || die "cannot quarantine divergent shared captain preferences"
  chmod 600 "$quarantine" || die "cannot secure shared-preference quarantine"
  printf 'quarantined: %s (%s)\n' "${quarantine#"$HOME_REAL/"}" "$reason" >&2
}

case "$COMMAND" in
  put)
    TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit.XXXXXX") || die "cannot stage inherited material"
    trap 'rm -f -- "$TMP"' EXIT
    head -c "$((MAX_BYTES + 1))" > "$TMP" || die "cannot read inherited material"
    BYTES=$(LC_ALL=C wc -c < "$TMP" | tr -d ' ')
    [ "$BYTES" -le "$MAX_BYTES" ] || die "inherited material exceeds the byte bound"
    if [ -f "$DEST" ] && cmp -s "$TMP" "$DEST"; then
      [ "$REL" != data/captain-shared.md ] || chmod 444 "$DEST"
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    quarantine_shared replaced
    chmod 600 "$TMP" || die "cannot secure inherited material"
    mv -f -- "$TMP" "$DEST" || die "cannot publish inherited material"
    trap - EXIT
    [ "$REL" != data/captain-shared.md ] || chmod 444 "$DEST"
    printf 'pushed: %s\n' "$REL"
    ;;
  absent)
    if [ ! -e "$DEST" ]; then
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    quarantine_shared removed
    rm -f -- "$DEST" || die "cannot remove absent inherited material"
    printf 'removed: %s\n' "$REL"
    ;;
  *) usage ;;
esac
