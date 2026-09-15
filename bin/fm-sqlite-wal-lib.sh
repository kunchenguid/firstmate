# shellcheck shell=bash
# Shared detection for hosts that cannot share a SQLite WAL database across processes.
# Usage: . bin/fm-sqlite-wal-lib.sh
#          fm_sqlite_wal_host_suspect              0 when this host is worth probing
#          fm_sqlite_wal_probe [<dir>] [<timeout>] 0 supported, 1 unsupported, 2 unverified
#          fm_sqlite_wal_probe_detail              the probe's one-line detail
#          fm_sqlite_wal_kernel                    the kernel release the verdict was taken on
#
# ONE OWNER for "can two processes hold this host's SQLite WAL database at
# once". no-mistakes keeps its pipeline state in a WAL database at
# ~/.no-mistakes/state.sqlite that its daemon holds open, so on a host without
# cross-process WAL support every CLI call that runs while the daemon is up
# fails with SQLITE_PROTOCOL (15) - "locking protocol" - and the no-mistakes
# delivery mode is unavailable for every project in the fleet.
#
# The verdict always comes from bin/fm-sqlite-wal-probe.py, which runs two real
# processes against a real WAL database. Nothing here infers a verdict from a
# kernel version string: the version only decides whether spending the probe is
# worth it, because the condition is confined to WSL and a normal host must not
# pay for a check it cannot fail.
#
# Why the gate is "is this WSL at all" rather than "is this WSL1": a WSL2 host
# passes the probe in well under a second, so a generous gate costs almost
# nothing and keeps the check from resting on the exact spelling of a release
# string. WSL1 is the host class known to fail, and its failure is kernel-level
# rather than filesystem-level - it reproduces on every filesystem WSL1 offers,
# so relocating the database does not avoid it.

FM_SQLITE_WAL_PROBE_TIMEOUT_DEFAULT=3
FM_SQLITE_WAL_PROBE_DETAIL=''

fm_sqlite_wal_kernel() {
  if [ -n "${FM_FAKE_KERNEL_RELEASE:-}" ]; then
    printf '%s\n' "$FM_FAKE_KERNEL_RELEASE"
    return 0
  fi
  uname -r 2>/dev/null || printf 'unknown\n'
}

fm_sqlite_wal_root_fstype() {
  if [ -n "${FM_FAKE_ROOT_FSTYPE:-}" ]; then
    printf '%s\n' "$FM_FAKE_ROOT_FSTYPE"
    return 0
  fi
  stat -f -c %T / 2>/dev/null || printf 'unknown\n'
}

# Cheap gate only. Three independent WSL signals, any one of which is enough to
# spend the probe, so no single vendor spelling is load-bearing.
fm_sqlite_wal_host_suspect() {
  local release fstype
  release=$(fm_sqlite_wal_kernel)
  case "$release" in
    *[Mm]icrosoft* | *WSL*) return 0 ;;
  esac
  fstype=$(fm_sqlite_wal_root_fstype)
  case "$fstype" in
    lxfs | wslfs) return 0 ;;
  esac
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  [ -n "${WSL_INTEROP:-}" ] && return 0
  return 1
}

fm_sqlite_wal_probe_detail() {
  printf '%s\n' "$FM_SQLITE_WAL_PROBE_DETAIL"
}

# Runs the real two-process probe. <dir> defaults to the directory that actually
# holds the no-mistakes state database, so the verdict is taken on the same
# filesystem the pipeline uses; it falls back to TMPDIR when that directory is
# not usable.
fm_sqlite_wal_probe() {
  local dir=${1:-} timeout=${2:-$FM_SQLITE_WAL_PROBE_TIMEOUT_DEFAULT}
  local script out rc

  FM_SQLITE_WAL_PROBE_DETAIL=''
  if [ -z "$dir" ]; then
    dir="${FM_NO_MISTAKES_HOME:-$HOME/.no-mistakes}"
    [ -d "$dir" ] && [ -w "$dir" ] || dir=${TMPDIR:-/tmp}
  fi

  script=${FM_SQLITE_WAL_PROBE_BIN:-$(dirname "${BASH_SOURCE[0]}")/fm-sqlite-wal-probe.py}
  if [ ! -x "$script" ]; then
    FM_SQLITE_WAL_PROBE_DETAIL="probe helper $script is not executable"
    return 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    FM_SQLITE_WAL_PROBE_DETAIL='python3 is not available to run the probe'
    return 2
  fi

  out=$("$script" "$dir" --timeout "$timeout" 2>&1)
  rc=$?
  FM_SQLITE_WAL_PROBE_DETAIL=${out#*: }
  [ "$out" = supported ] && FM_SQLITE_WAL_PROBE_DETAIL='supported'
  return "$rc"
}
