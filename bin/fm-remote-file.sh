#!/usr/bin/env bash
# Path-confined remote file transfer for fm-on.sh.
#
# Usage:
#   fm-remote-file.sh get <relative-path> [max-bytes]
#   fm-remote-file.sh put state/handoff/<id>.outbox.md [max-bytes]
#
# A get path is relative to FM_HOME, must resolve through ordinary directories
# to one non-symlink regular file inside that home, and is bounded before output.
# Put is deliberately narrower: it atomically replaces only a backlog handoff
# scratch file under state/handoff. There is no delete operation and no generic
# write path; the receiving command owns scratch cleanup after committed ingest.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_DEFAULT=262144

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

resolve_file() { # <relative-path>
  local rel=$1 parent base home_real parent_real path
  case "$rel" in ''|/*|*'//'*) die "path must be a nonempty relative path" ;; esac
  case "/$rel/" in */../*|*/./*) die "path traversal is not allowed: $rel" ;; esac
  case "$rel" in *$'\n'*|*$'\r'*|*$'\t'*) die "path contains control characters" ;; esac
  home_real=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
  parent=$(dirname "$rel")
  base=$(basename "$rel")
  parent_real=$(CDPATH='' cd -- "$FM_HOME/$parent" 2>/dev/null && pwd -P) || die "file parent is unavailable: $rel"
  case "$parent_real" in "$home_real"|"$home_real"/*) ;; *) die "file escapes FM_HOME: $rel" ;; esac
  path="$parent_real/$base"
  [ -f "$path" ] && [ ! -L "$path" ] || die "file is not a non-symlink regular file: $rel"
  printf '%s\n' "$path"
}

COMMAND=${1:-}
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
REL=$2
MAX=${3:-$MAX_DEFAULT}
case "$MAX" in ''|*[!0-9]*|0) die "max-bytes must be a positive integer" ;; esac
[ "$MAX" -le 1048576 ] || die "max-bytes exceeds the 1048576-byte safety bound"
case "$COMMAND" in
  get)
    FILE=$(resolve_file "$REL")
    BYTES=$(LC_ALL=C wc -c < "$FILE" | tr -d ' ')
    [ "$BYTES" -le "$MAX" ] || die "file exceeds max-bytes: $REL ($BYTES > $MAX)"
    cat "$FILE"
    ;;
  put)
    case "$REL" in state/handoff/*.outbox.md) ;; *) die "put is confined to state/handoff/<id>.outbox.md" ;; esac
    NAME=${REL#state/handoff/}
    ID=${NAME%.outbox.md}
    case "$ID" in ''|*[!A-Za-z0-9._-]*) die "put path has an unsafe handoff id" ;; esac
    case "$NAME" in */*) die "put path has an extra directory" ;; esac
    case "/$REL/" in */../*|*/./*) die "put path contains traversal" ;; esac
    case "$REL" in *'//'*) die "put path is malformed" ;; esac
    HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
    STATE_DIR="$HOME_REAL/state"
    [ ! -L "$STATE_DIR" ] || die "state directory must not be a symlink"
    mkdir -p "$STATE_DIR" || die "cannot create state directory"
    HANDOFF_DIR="$STATE_DIR/handoff"
    [ ! -L "$HANDOFF_DIR" ] || die "handoff directory must not be a symlink"
    mkdir -p "$HANDOFF_DIR" || die "cannot create handoff directory"
    DEST="$HANDOFF_DIR/$(basename "$REL")"
    [ ! -L "$DEST" ] || die "handoff destination must not be a symlink"
    TMP=$(umask 077; mktemp "$HANDOFF_DIR/.put.XXXXXX") || die "cannot stage handoff transfer"
    if ! head -c "$((MAX + 1))" > "$TMP"; then
      rm -f -- "$TMP"
      die "cannot read handoff transfer"
    fi
    BYTES=$(LC_ALL=C wc -c < "$TMP" | tr -d ' ')
    if [ "$BYTES" -gt "$MAX" ]; then
      rm -f -- "$TMP"
      die "handoff transfer exceeds max-bytes"
    fi
    chmod 600 "$TMP" || { rm -f -- "$TMP"; die "cannot secure handoff transfer"; }
    mv -f -- "$TMP" "$DEST" || { rm -f -- "$TMP"; die "cannot publish handoff transfer"; }
    printf 'stored: %s bytes=%s\n' "$REL" "$BYTES"
    ;;
  *) usage ;;
esac
