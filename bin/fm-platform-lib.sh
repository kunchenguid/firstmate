#!/usr/bin/env bash
# shellcheck shell=bash
# Where the host filesystem and the MSYS (Git Bash) world disagree with what
# firstmate's POSIX code assumes: path form, and whether modes are real.
#
# ONE owner of each of those questions. Two copies of either rule would drift,
# and both are the kind of rule that is only exercised on one platform, so the
# copy nobody runs is the copy that rots.
#
# Path form. A Git Bash home speaks POSIX paths (/tmp/x, /c/Users/x) while a
# native Windows program launched from it resolves only Windows paths
# (C:/Users/x). Every place firstmate hands a path across that boundary must go
# through here, so the rule lives in one file rather than being re-derived per
# call site.
#
# WARNING - converting the wrong value is worse than not converting at all.
# Convert ONLY a value handed to a native, non-MSYS program: go.exe, node.exe,
# a native CLI. Never convert a path an MSYS tool consumes, and never convert
# a path baked into a generated pane hook. The generated grok turn-end hook in
# bin/fm-spawn.sh matches its argument against `/*.turn-ended`; a Windows-form
# path fails that pattern, so the hook exits 0 and the whole turn-end
# continuity layer goes quiet with no error anywhere.
#
# This file is sourced by scripts and has no side effects on source.
#
# cygpath is resolved through `command -v` on every call, so a test can inject
# a fixture ahead of it on PATH. When cygpath is absent, or runs and fails, the
# input is printed unchanged: a partial or empty conversion of a non-empty path
# is never emitted, because a caller cannot tell that apart from a real answer.
#
# Mode bits. Git Bash's default NTFS mounts are noacl: chmod is a silent no-op
# and every file reports the mount's fixed modes, so any exact-mode contract
# refuses artifacts that are in fact private and blocks the feature outright.
# fm_platform_fs_honors_modes answers whether an exact-mode check means anything
# on a given filesystem, so a caller can keep its structural guards always and
# apply the mode equality only where a mode can actually be stored.
#
# Opt-in. Native Windows support is off until a home asks for it with
# FM_WINDOWS=1, so landing this code changes nothing for a home that has not
# opted in, on any platform.
# Running under Git Bash is a necessary condition, never a sufficient one: a
# host is only a candidate, and the captain's FM_WINDOWS=1 is the consent.
# Two owners, because two different questions are being asked.
# fm_platform_windows_opt_in is consent alone. fm_platform_windows_enabled is
# consent plus the platform, and every behavioural Windows path gates on it
# rather than on the raw platform fact.
# The mode contract below reads consent alone on purpose. Without the opt-in it
# keeps the strict exact-mode answer even on a filesystem that provably cannot
# store a mode, because silently relaxing a privacy guard is not a decision a
# platform probe is allowed to make. Requiring MSYS there as well would only
# make the probe unreachable on the hosts CI runs, which is how a guard rots.
#
# Env seams, mainly for tests:
#   FM_WINDOWS           1 opts this home in to native Windows support. Any
#                        other value, or unset, leaves every Windows path inert.
#   FM_PLATFORM_UNAME    replace `uname -s`, so the MSYS branch can be driven
#                        on any host.
#   FM_FS_MODES_HONORED  override the mode probe: 1 keeps the exact-mode
#                        contract, 0 declares modes unrepresentable. Unset
#                        probes the filesystem. Only consulted once the home has
#                        opted in, so it cannot weaken a home that has not.
# FM_PLATFORM_MSYS caches the probed platform verdict for this process, and
# FM_PLATFORM_MODES_PROBED_* the mode verdict for one directory; empty means
# the verdict has not been taken yet.

FM_PLATFORM_MSYS=${FM_PLATFORM_MSYS:-}

# Print the kernel name this host reports.
fm_platform_uname() {
  printf '%s\n' "${FM_PLATFORM_UNAME:-$(uname -s)}"
}

# True when this shell runs under MSYS/MinGW (Git Bash).
fm_platform_is_msys() {
  if [ -z "$FM_PLATFORM_MSYS" ]; then
    case "$(fm_platform_uname)" in
      MINGW*|MSYS*) FM_PLATFORM_MSYS=1 ;;
      *) FM_PLATFORM_MSYS=0 ;;
    esac
  fi
  [ "$FM_PLATFORM_MSYS" = 1 ]
}

# True when this home asked for native Windows support. Consent alone, with no
# platform claim attached, so a caller whose guard is about consent rather than
# about MSYS can read it directly and stays exercisable on any host.
fm_platform_windows_opt_in() {
  [ "${FM_WINDOWS:-}" = 1 ]
}

# True when this home has opted in AND the host can actually provide it. Gate
# platform behaviour on this, never on fm_platform_is_msys: the latter is a
# platform fact, this is the consent to act on it.
fm_platform_windows_enabled() {
  fm_platform_windows_opt_in && fm_platform_is_msys
}

# Print the form a native Windows binary resolves.
#
# cygpath -m yields the mixed form (C:/Users/x): a drive letter with forward
# slashes, so the result needs no escaping inside JSON or a quoted shell word.
fm_path_native() {  # <path>
  local path=$1 cygpath out
  [ -n "$path" ] || return 0
  if fm_platform_windows_enabled && cygpath=$(command -v cygpath 2>/dev/null); then
    if out=$("$cygpath" -m -- "$path" 2>/dev/null) && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  printf '%s\n' "$path"
}

# Print the POSIX form MSYS tools use.
fm_path_posix() {  # <path>
  local path=$1 cygpath out
  [ -n "$path" ] || return 0
  if fm_platform_windows_enabled && cygpath=$(command -v cygpath 2>/dev/null); then
    if out=$("$cygpath" -u -- "$path" 2>/dev/null) && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  printf '%s\n' "$path"
}

# Print the octal mode bits of <path>, or nothing when it cannot be read.
fm_platform_file_mode() {  # <path>
  if [ "$(fm_platform_uname)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

# Whether the filesystem holding <path>'s directory actually stores POSIX mode
# bits. On a noacl mount the Windows user-profile ACL is the privacy boundary
# instead, and a caller's structural guards (regular file or directory, no
# symlink, owning uid, device pin, link count) still hold in full.
# Probed with a throwaway file and cached per directory per process. A probe
# that cannot run at all reports modes-honored, so an unexpected filesystem
# keeps the strict contract rather than quietly dropping it.
FM_PLATFORM_MODES_PROBED_DIR=
FM_PLATFORM_MODES_PROBED_VERDICT=
fm_platform_fs_honors_modes() {  # <path-on-target-filesystem>
  local dir probe_file mode
  # Before any probe or seam: a home that has not opted in keeps the strict
  # exact-mode contract it had before this code existed, so landing the Windows
  # work cannot relax a privacy guard anywhere by default.
  # Consent, not platform. A filesystem that cannot store a mode is a fact worth
  # answering wherever it is true, and tying the answer to MSYS as well would
  # make the probe unreachable on every host CI actually runs.
  fm_platform_windows_opt_in || return 0
  case "${FM_FS_MODES_HONORED:-}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  dir=$(dirname "$1")
  if [ "${FM_PLATFORM_MODES_PROBED_DIR:-}" = "$dir" ]; then
    [ "${FM_PLATFORM_MODES_PROBED_VERDICT:-}" = honors ]
    return
  fi
  probe_file=$(mktemp "$dir/.fm-mode-probe.XXXXXX" 2>/dev/null) || return 0
  chmod 0600 "$probe_file" 2>/dev/null
  mode=$(fm_platform_file_mode "$probe_file")
  rm -f "$probe_file"
  FM_PLATFORM_MODES_PROBED_DIR=$dir
  if [ "$mode" = 600 ]; then
    FM_PLATFORM_MODES_PROBED_VERDICT=honors
    return 0
  fi
  FM_PLATFORM_MODES_PROBED_VERDICT=ignores
  return 1
}
