#!/usr/bin/env bash
# Shared owner-only regular-file and atomic-publication primitives.
#
# This file is sourced, never executed.
# It is the single owner of the local-file identity boundary used by private
# remote-channel configuration and runtime artifacts:
#   fm_private_file_valid <path> <mode>
#   fm_private_read_file <path> <mode>
#   fm_private_dir_prepare <path>
#   fm_private_publish_stdin <dir> <base> <mode>
#   fm_private_publish_stdin_once <dir> <base> <mode>
#
# Files must be owned by the current uid, regular, single-link, non-symlink,
# and exactly mode 0600 or 0700 as requested.
# Reads open with O_NOFOLLOW and validate the opened descriptor, closing the
# validation/read race that a separate test-then-cat sequence would leave.

fm_private_mode_ok() {
  case "$1" in
    600|700) return 0 ;;
    *) return 1 ;;
  esac
}

fm_private_base_ok() {
  case "$1" in
    ''|.*|*/*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_private_file_valid() { # <path> <mode>
  local path=$1 mode=$2
  fm_private_mode_ok "$mode" || return 1
  perl -MFcntl=:DEFAULT -e '
    my ($path, $expected) = @ARGV;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @st = stat($fh) or exit 1;
    exit 1 unless -f _;
    exit 1 unless $st[3] == 1;
    exit 1 unless $st[4] == $<;
    exit 1 unless (($st[2] & 07777) == oct($expected));
  ' "$path" "$mode" 2>/dev/null
}

fm_private_read_file() { # <path> <mode>
  local path=$1 mode=$2
  fm_private_mode_ok "$mode" || return 1
  perl -MFcntl=:DEFAULT -e '
    my ($path, $expected) = @ARGV;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @st = stat($fh) or exit 1;
    exit 1 unless -f _;
    exit 1 unless $st[3] == 1;
    exit 1 unless $st[4] == $<;
    exit 1 unless (($st[2] & 07777) == oct($expected));
    binmode($fh);
    while (1) {
      my $n = read($fh, my $buf, 65536);
      exit 1 unless defined $n;
      last unless $n;
      print $buf or exit 1;
    }
  ' "$path" "$mode" 2>/dev/null
}

fm_private_dir_valid() { # <path>
  local path=$1
  perl -MFcntl=:DEFAULT -e '
    my ($path) = @ARGV;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @st = stat($fh) or exit 1;
    exit 1 unless -d _;
    exit 1 unless $st[4] == $<;
    exit 1 unless (($st[2] & 07777) == 0700);
  ' "$path" 2>/dev/null
}

fm_private_sync_file() { # <path> <mode>
  local path=$1 mode=$2
  fm_private_mode_ok "$mode" || return 1
  perl -MFcntl=:DEFAULT -MIO::Handle -e '
    my ($path, $expected) = @ARGV;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @st = stat($fh) or exit 1;
    exit 1 unless -f _;
    exit 1 unless $st[3] == 1;
    exit 1 unless $st[4] == $<;
    exit 1 unless (($st[2] & 07777) == oct($expected));
    $fh->sync or exit 1;
  ' "$path" "$mode" 2>/dev/null
}

fm_private_sync_dir() { # <path>
  local path=$1
  perl -MFcntl=:DEFAULT -MIO::Handle -e '
    my ($path) = @ARGV;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @st = stat($fh) or exit 1;
    exit 1 unless -d _;
    exit 1 unless $st[4] == $<;
    exit 1 unless (($st[2] & 07777) == 0700);
    $fh->sync or exit 1;
  ' "$path" 2>/dev/null
}

fm_private_dir_prepare() { # <path>
  local dir=$1 parent
  parent=${dir%/*}
  [ -n "$dir" ] && [ "$parent" != "$dir" ] || return 1
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  else
    (umask 077; mkdir -p -- "$parent") 2>/dev/null || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  fi
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    chmod 0700 "$dir" 2>/dev/null || return 1
  else
    (umask 077; mkdir -- "$dir") 2>/dev/null || return 1
  fi
  fm_private_dir_valid "$dir"
}

fm_private_publish_stdin() { # <dir> <base> <mode>
  local dir=$1 base=$2 mode=$3 tmp dest
  fm_private_base_ok "$base" || return 1
  fm_private_mode_ok "$mode" || return 1
  fm_private_dir_prepare "$dir" || return 1
  dest="$dir/$base"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fm_private_file_valid "$dest" "$mode" || return 1
  fi
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-private.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_private_file_valid "$tmp" "$mode" \
    || ! fm_private_sync_file "$tmp" "$mode"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_private_sync_dir "$dir" || return 1
  fm_private_file_valid "$dest" "$mode"
}

fm_private_publish_stdin_once() { # <dir> <base> <mode>
  local dir=$1 base=$2 mode=$3 tmp dest
  fm_private_base_ok "$base" || return 2
  fm_private_mode_ok "$mode" || return 2
  fm_private_dir_prepare "$dir" || return 2
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-private.XXXXXX" 2>/dev/null) || return 2
  if ! cat > "$tmp" \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_private_file_valid "$tmp" "$mode" \
    || ! fm_private_sync_file "$tmp" "$mode"; then
    rm -f -- "$tmp"
    return 2
  fi
  if ln -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    fm_private_sync_dir "$dir" || return 2
    fm_private_file_valid "$dest" "$mode" || return 2
    return 0
  fi
  rm -f -- "$tmp"
  fm_private_file_valid "$dest" "$mode" && return 1
  return 2
}
