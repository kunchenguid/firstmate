#!/usr/bin/env bash
# Path-confined remote file transfer for fm-on.sh.
#
# Usage:
#   fm-remote-file.sh get <relative-path> [max-bytes]
#   fm-remote-file.sh put state/handoff/<id>.outbox.md <max-bytes> <bytes> <sha256> <generation>
#
# A get path is relative to FM_HOME, must resolve through ordinary directories
# to one non-symlink regular file inside that home, and is bounded before output.
# Put is deliberately narrower: it atomically replaces only a backlog handoff
# scratch file under state/handoff. There is no delete operation and no generic
# write path; the receiving command owns scratch cleanup after committed ingest.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_DEFAULT=262144
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

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
    /usr/bin/stat -f '%d:%i' . 2>/dev/null
  else
    stat -c '%d:%i' . 2>/dev/null
  fi
}

put_handoff_file() { # <home-real> <name> <max-bytes> <relative-path> <bytes> <sha256> <generation>
  local home_real=$1 name=$2 max=$3 rel=$4 expected_bytes=$5 expected_hash=$6 generation=$7
  local state_real handoff_real pinned named tmp bytes actual_hash lock generation_file generation_tmp
  local stored_generation stored_bytes stored_hash
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
    lock="./.$ID.upload.lock"
    fm_lock_acquire_wait "$lock" || exit 5
    tmp=
    generation_tmp=
    cleanup_put() {
      [ -z "$tmp" ] || rm -f -- "$tmp"
      [ -z "$generation_tmp" ] || rm -f -- "$generation_tmp"
      fm_lock_release "$lock" || true
    }
    trap cleanup_put EXIT
    tmp=$(umask 077; mktemp './.put.XXXXXX') || exit 5
    head -c "$((max + 1))" > "$tmp" || exit 5
    bytes=$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')
    [ "$bytes" -le "$max" ] || exit 4
    [ "$bytes" -eq "$expected_bytes" ] || exit 6
    actual_hash=$(sha256_file "$tmp") || exit 5
    [ "$actual_hash" = "$expected_hash" ] || exit 6
    chmod 600 "$tmp" || exit 5
    named=$(CDPATH='' cd -- "$home_real/state/handoff" 2>/dev/null && directory_identity) || exit 3
    [ "$named" = "$pinned" ] || exit 3
    [ ! -L "$name" ] || exit 3
    generation_file="./.$ID.upload-generation"
    if [ -e "$generation_file" ] || [ -L "$generation_file" ]; then
      [ -f "$generation_file" ] && [ ! -L "$generation_file" ] || exit 3
      {
        IFS= read -r stored_generation \
          && IFS= read -r stored_bytes \
          && IFS= read -r stored_hash \
          && ! IFS= read -r
      } < "$generation_file" || exit 3
      case "$stored_generation" in ''|*[!0-9]*) exit 3 ;; esac
      [ "${#stored_generation}" -le 18 ] || exit 3
      case "$stored_bytes" in ''|*[!0-9]*) exit 3 ;; esac
      case "$stored_hash" in ''|*[!A-Fa-f0-9]*) exit 3 ;; esac
      [ "${#stored_hash}" -eq 64 ] || exit 3
      [ "$stored_generation" -le "$generation" ] || exit 7
      if [ "$stored_generation" -eq "$generation" ]; then
        [ "$stored_bytes" = "$expected_bytes" ] && [ "$stored_hash" = "$expected_hash" ] || exit 7
      fi
    fi
    if [ ! -e "$generation_file" ] || [ "$stored_generation" -lt "$generation" ]; then
      generation_tmp=$(umask 077; mktemp './.put-generation.XXXXXX') || exit 5
      printf '%s\n%s\n%s\n' "$generation" "$expected_bytes" "$expected_hash" > "$generation_tmp" || exit 5
      chmod 600 "$generation_tmp" || exit 5
      mv -f -- "$generation_tmp" "$generation_file" || exit 5
      generation_tmp=
    fi
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
    cleanup_put
    trap - EXIT
    printf 'stored: %s bytes=%s\n' "$rel" "$bytes"
  )
}

COMMAND=${1:-}
[ "$#" -ge 2 ] || usage
REL=$2
MAX=${3:-$MAX_DEFAULT}
case "$MAX" in ''|*[!0-9]*|0) die "max-bytes must be a positive integer" ;; esac
[ "$MAX" -le 1048576 ] || die "max-bytes exceeds the 1048576-byte safety bound"
case "$COMMAND" in
  get)
    [ "$#" -le 3 ] || usage
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
    [ "$#" -eq 6 ] || usage
    EXPECTED_BYTES=$4
    EXPECTED_HASH=$5
    GENERATION=$6
    case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
    [ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes exceed max-bytes"
    [ "$EXPECTED_BYTES" -le "$MAX" ] || die "expected bytes exceed max-bytes"
    case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
    [ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
    EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
    case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
    [ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
    case "$REL" in state/handoff/*.outbox.md) ;; *) die "put is confined to state/handoff/<id>.outbox.md" ;; esac
    NAME=${REL#state/handoff/}
    ID=${NAME%.outbox.md}
    case "$ID" in ''|*[!A-Za-z0-9._-]*) die "put path has an unsafe handoff id" ;; esac
    case "$NAME" in */*) die "put path has an extra directory" ;; esac
    case "/$REL/" in */../*|*/./*) die "put path contains traversal" ;; esac
    case "$REL" in *'//'*) die "put path is malformed" ;; esac
    HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
    if put_handoff_file "$HOME_REAL" "$(basename "$REL")" "$MAX" "$REL" \
      "$EXPECTED_BYTES" "$EXPECTED_HASH" "$GENERATION"; then
      :
    else
      rc=$?
      case "$rc" in
        3) die "handoff directory changed into an unsafe path" ;;
        4) die "handoff transfer exceeds max-bytes" ;;
        6) die "handoff transfer does not match its payload commitment" ;;
        7) die "handoff transfer generation is superseded or conflicting" ;;
        *) die "cannot publish handoff transfer" ;;
      esac
    fi
    ;;
  *) usage ;;
esac
