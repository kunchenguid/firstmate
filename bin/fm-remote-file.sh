#!/usr/bin/env bash
# Path-confined remote file reads for fm-on.sh.
#
# Usage:
#   fm-remote-file.sh get <relative-path> [max-bytes]
#
# The path is relative to FM_HOME, must resolve through ordinary directories to
# one non-symlink regular file inside that home, and is bounded before output.
# There is deliberately no delete or arbitrary write operation in this command.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_DEFAULT=262144

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

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

[ "${1:-}" = get ] || usage
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
REL=$2
MAX=${3:-$MAX_DEFAULT}
case "$MAX" in ''|*[!0-9]*|0) die "max-bytes must be a positive integer" ;; esac
[ "$MAX" -le 1048576 ] || die "max-bytes exceeds the 1048576-byte safety bound"
FILE=$(resolve_file "$REL")
BYTES=$(LC_ALL=C wc -c < "$FILE" | tr -d ' ')
[ "$BYTES" -le "$MAX" ] || die "file exceeds max-bytes: $REL ($BYTES > $MAX)"
cat "$FILE"
