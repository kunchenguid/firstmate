# shellcheck shell=bash
# Shared helpers for bin/fm-progress-report.sh.
# Usage: . bin/fm-progress-report-lib.sh

fm_progress_die() {
  printf 'fm-progress-report: %s\n' "$1" >&2
  exit "${2:-1}"
}

fm_progress_now_ms() {
  case "${FM_PROGRESS_NOW_MS:-}" in
    ''|*[!0-9]*) date +%s000 2>/dev/null || printf '0\n' ;;
    *) printf '%s\n' "$FM_PROGRESS_NOW_MS" ;;
  esac
}

fm_progress_now_epoch() {
  local ms
  ms=$(fm_progress_now_ms) || return 1
  printf '%s\n' $((ms / 1000))
}

fm_progress_bar() { # <value> <max>
  local value=${1:-0} max=${2:-0} filled i
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  case "$max" in ''|*[!0-9]*|0) printf '%14s' '' | tr ' ' '░'; return 0 ;; esac
  filled=$(( (14 * value + max / 2) / max ))
  [ "$filled" -gt 14 ] && filled=14
  [ "$filled" -lt 0 ] && filled=0
  for ((i = 0; i < filled; i++)); do printf '█'; done
  for ((i = filled; i < 14; i++)); do printf '░'; done
}

# Refuse when any component of the given path is a symlink (the final
# directory or any ancestor), so a symlinked ancestor cannot redirect state
# writes. Prints the validated physical path.
fm_progress_safe_dir() { # <path> <label>
  local path=$1 label=$2 resolved walk
  [ -n "$path" ] || fm_progress_die "$label path is empty" 1
  [ -e "$path" ] || fm_progress_die "$label is missing: $path" 1
  [ -d "$path" ] || fm_progress_die "$label is not a directory: $path" 1
  case "$path" in
    /*) walk=$path ;;
    *)  walk=$PWD/$path ;;
  esac
  while :; do
    [ ! -L "$walk" ] || fm_progress_die "$label must not pass through a symlink: $walk" 1
    [ "$walk" != / ] || break
    walk=$(dirname "$walk")
  done
  resolved=$(cd "$path" 2>/dev/null && pwd -P) || fm_progress_die "$label cannot be resolved: $path" 1
  printf '%s\n' "$resolved"
}

# Cheap identity token for a validated directory (device:inode), used to prove
# the directory is unchanged between validation and the atomic rename.
fm_progress_dir_token() { # <path>
  local token
  token=$(/usr/bin/stat -f '%d:%i' "$1" 2>/dev/null) || token=$(stat -c '%d:%i' "$1" 2>/dev/null) \
    || fm_progress_die "cannot identity-stat directory: $1" 1
  printf '%s\n' "$token"
}

# Atomic state commit bound to the validated directory inode. The process
# holds a descriptor to the directory and fchdirs into it, so the temp
# creation, rename, committed-file reopen, and any cleanup all resolve
# relative to the held inode - a path exchange anywhere outside can neither
# redirect the commit nor place a file in an unvalidated directory. The
# committed bytes are read back and compared before success. Content arrives
# on stdin.
# Test seam: FM_PROGRESS_TEST_SEAM=1 plus FM_PROGRESS_TEST_SWAP_HOOK=<cmd> runs
# <cmd> inside the critical section so tests can exchange the path mid-commit.
fm_progress_atomic_write() { # <path> <content>
  local path=$1 content=$2 dir base token
  dir=$(fm_progress_safe_dir "$(dirname "$path")" 'state directory')
  base=$(basename "$path")
  case "$base" in ''|*[!A-Za-z0-9._-]*) fm_progress_die "state file name is unsafe: $base" 1 ;; esac
  [ ! -e "$dir/$base" ] || [ -f "$dir/$base" ] || fm_progress_die "state path is not a regular file: $dir/$base" 1
  [ ! -L "$dir/$base" ] || fm_progress_die "state path must not be a symlink: $dir/$base" 1
  token=$(fm_progress_dir_token "$dir")
  printf '%s' "$content" | perl -MFcntl=:DEFAULT -MCwd=getcwd -e '
    my ($dir, $base, $token) = @ARGV;
    my $cwd = getcwd() or exit 2;
    sysopen(my $dfh, $dir, O_RDONLY) or exit 3;
    my @fst = stat($dfh);
    @fst && "$fst[0]:$fst[1]" eq $token or exit 4;
    # Move into the held directory descriptor: every operation below is
    # relative to the validated inode, never to a re-resolvable path.
    if ($^O eq "darwin") {
      syscall(13, fileno($dfh)) == 0 or exit 3; # fchdir
    } else {
      chdir("/proc/self/fd/" . fileno($dfh)) or exit 3;
    }
    my @here = lstat(".");
    @here && -d _ && "$here[0]:$here[1]" eq $token or exit 4;
    my $tmp = sprintf(".progress-report.%d-%d", $$, int(rand(1000000)));
    my $content = do { local $/; <STDIN> };
    sysopen(my $tfh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or exit 5;
    print $tfh $content or exit 6;
    close $tfh or exit 6;
    my @tst = lstat($tmp);
    @tst or do { unlink $tmp; exit 6 };
    my $tmp_ino = $tst[1];
    if ($ENV{FM_PROGRESS_TEST_SEAM} and my $hook = $ENV{FM_PROGRESS_TEST_SWAP_HOOK}) {
      system($hook);
    }
    rename($tmp, $base) or do { unlink $tmp; exit 8 };
    # Verify against the held inode and the exact staged bytes.
    my @vl = lstat($base);
    my $isfile = @vl && -f _;
    my $ok = $isfile && $vl[1] == $tmp_ino;
    if ($ok) {
      sysopen(my $vfh, $base, O_RDONLY | O_NOFOLLOW) or do { $ok = 0 };
      if ($ok) {
        my $back = do { local $/; <$vfh> };
        $ok = defined $back && $back eq $content;
      }
    }
    unless ($ok) {
      if (@vl && $vl[1] == $tmp_ino) { unlink $base; }
      chdir $cwd;
      exit 10;
    }
    chdir $cwd or exit 11;
    exit 0;
  ' "$dir" "$base" "$token" || fm_progress_die "atomic state commit failed: $dir/$base" 1
}

fm_progress_sha256() {
  local digest input record
  input=$(cat) || fm_progress_die 'sha256 input read failed' 1
  [ -n "$input" ] || fm_progress_die 'sha256 input is empty' 1
  if command -v shasum >/dev/null 2>&1; then
    record=$(printf '%s' "$input" | shasum -a 256) \
      || fm_progress_die 'sha256 command failed' 1
  elif command -v sha256sum >/dev/null 2>&1; then
    record=$(printf '%s' "$input" | sha256sum) \
      || fm_progress_die 'sha256 command failed' 1
  else
    fm_progress_die 'sha256 helper is unavailable' 1
  fi
  # Exactly one complete output record in the tool's stdin grammar:
  # 64 lowercase hex, two spaces, the '-' stdin marker, nothing else.
  case "$record" in
    *"\n"*) fm_progress_die "sha256 output is not one record" 1 ;;
  esac
  digest=${record%  -}
  if [ "$digest" = "$record" ]; then
    fm_progress_die "sha256 output is not in the expected grammar" 1
  fi
  case "$digest" in
    *[!0-9a-f]*) fm_progress_die "sha256 digest is not lowercase hex" 1 ;;
  esac
  [ "${#digest}" -eq 64 ] || fm_progress_die "sha256 digest is not 64 hex characters" 1
  printf '%s\n' "$digest"
}

fm_progress_read_file() { # <path> <label>
  local path=$1 label=$2
  [ -n "$path" ] || fm_progress_die "$label path is empty" 1
  [ -f "$path" ] || fm_progress_die "$label is missing: $path" 1
  [ ! -L "$path" ] || fm_progress_die "$label is not a regular file: $path" 1
  cat -- "$path" || fm_progress_die "$label is unreadable: $path" 1
}
