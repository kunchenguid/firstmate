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

snapshot_bounded_file() { # <file> <max-bytes> <destination> <size-file>
  local file=$1 max=$2 destination=$3 size_file=$4 parent base actual_parent
  parent=$(dirname "$file")
  base=$(basename "$file")
  (
    CDPATH='' cd -- "$parent" 2>/dev/null || exit 3
    actual_parent=$(pwd -P) || exit 3
    [ "$actual_parent" = "$parent" ] || exit 3
    perl -MFcntl=:DEFAULT -e '
      my ($path, $max, $destination, $size_file) = @ARGV;
      sysopen(my $source, $path, O_RDONLY | O_NOFOLLOW) or exit 3;
      my @stat = stat $source or exit 3;
      exit 3 unless -f _;
      my $size = $stat[7];
      exit 3 unless $size =~ /\A\d+\z/;
      exit 4 if $size > $max;
      open(my $output, ">", $destination) or exit 5;
      binmode $source;
      binmode $output;
      my $remaining = $size;
      while ($remaining > 0) {
        my $wanted = $remaining > 65536 ? 65536 : $remaining;
        my $read = read($source, my $buffer, $wanted);
        exit 5 unless defined $read && $read > 0;
        print {$output} $buffer or exit 5;
        $remaining -= $read;
      }
      close $output or exit 5;
      open(my $size_output, ">", $size_file) or exit 5;
      print {$size_output} "$size\n" or exit 5;
      close $size_output or exit 5;
    ' "$base" "$max" "$destination" "$size_file"
  )
}

directory_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' . 2>/dev/null
  else
    stat -c '%d:%i' . 2>/dev/null
  fi
}

put_handoff_file() { # <home-real> <name> <max-bytes> <relative-path>
  local home_real=$1 name=$2 max=$3 rel=$4 state_real handoff_real pinned named tmp bytes
  (
    CDPATH='' cd -- "$home_real" 2>/dev/null || exit 3
    [ "$(pwd -P)" = "$home_real" ] || exit 3
    if ! mkdir state 2>/dev/null; then
      [ -d state ] && [ ! -L state ] || exit 3
    fi
    [ -d state ] && [ ! -L state ] || exit 3
    CDPATH='' cd -- state 2>/dev/null || exit 3
    state_real=$(pwd -P) || exit 3
    [ "$state_real" = "$home_real/state" ] || exit 3
    if ! mkdir handoff 2>/dev/null; then
      [ -d handoff ] && [ ! -L handoff ] || exit 3
    fi
    [ -d handoff ] && [ ! -L handoff ] || exit 3
    CDPATH='' cd -- handoff 2>/dev/null || exit 3
    handoff_real=$(pwd -P) || exit 3
    [ "$handoff_real" = "$home_real/state/handoff" ] || exit 3
    pinned=$(directory_identity) || exit 3
    [ ! -L "$name" ] || exit 3
    tmp=$(umask 077; mktemp './.put.XXXXXX') || exit 5
    trap 'rm -f -- "$tmp"' EXIT
    head -c "$((max + 1))" > "$tmp" || exit 5
    bytes=$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')
    [ "$bytes" -le "$max" ] || exit 4
    chmod 600 "$tmp" || exit 5
    named=$(CDPATH='' cd -- "$home_real/state/handoff" 2>/dev/null && directory_identity) || exit 3
    [ "$named" = "$pinned" ] || exit 3
    [ ! -L "$name" ] || exit 3
    mv -f -- "$tmp" "./$name" || exit 5
    tmp=
    named=$(CDPATH='' cd -- "$home_real/state/handoff" 2>/dev/null && directory_identity) || {
      rm -f -- "./$name"
      exit 3
    }
    if [ "$named" != "$pinned" ]; then
      rm -f -- "./$name"
      exit 3
    fi
    trap - EXIT
    printf 'stored: %s bytes=%s\n' "$rel" "$bytes"
  )
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
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-file.XXXXXX") \
      || die "cannot create file staging directory"
    trap 'rm -rf -- "$TMP"' EXIT
    if snapshot_bounded_file "$FILE" "$MAX" "$TMP/file" "$TMP/size"; then
      BYTES=$(tr -d ' ' < "$TMP/size")
    else
      rc=$?
      case "$rc" in
        3) die "file changed into an unsafe file: $REL" ;;
        4) die "file exceeds max-bytes: $REL" ;;
        *) die "file could not be captured safely: $REL" ;;
      esac
    fi
    [ "$BYTES" -le "$MAX" ] || die "file exceeds max-bytes: $REL"
    cat "$TMP/file"
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
    if put_handoff_file "$HOME_REAL" "$(basename "$REL")" "$MAX" "$REL"; then
      :
    else
      rc=$?
      case "$rc" in
        3) die "handoff directory changed into an unsafe path" ;;
        4) die "handoff transfer exceeds max-bytes" ;;
        *) die "cannot publish handoff transfer" ;;
      esac
    fi
    ;;
  *) usage ;;
esac
