# shellcheck shell=bash
# fm-stat-lib.sh - the ONE owner of portable file-timestamp reads.
#
# Usage: . bin/fm-stat-lib.sh
#
# It defines:
#   fm_stat_mtime <path>  - mtime in whole epoch seconds
#   fm_stat_sig <path>    - opaque "<size>:<mtime>" change signature
#   fm_stat_mode <path>   - permission bits in octal (e.g. 600)
#   fm_stat_device <path> - device number
#   fm_stat_inode <path>  - inode number
#   fm_stat_nlink <path>  - hard link count
#   fm_stat_identity <path> - opaque full-metadata signature (device, inode,
#                           size, mtime, ctime)
#
# macOS (BSD) stat spells a format `-f <fmt>`; GNU coreutils stat spells it
# `-c <fmt>` and reads `-f` as *file-system* stat. Two shapes are therefore
# forbidden anywhere in this repo, and this library exists so no caller has to
# re-derive why:
#
#   `stat -f <fmt> "$p" || stat -c <fmt> "$p"` - on a GNU stat the first arm
#   writes a partial filesystem dump ("File: ...", "Blocks: ...") to STDOUT and
#   only then fails, so the second arm's correct epoch is appended to that
#   garbage. The chain exits zero with invalid output, and arithmetic on it
#   aborts on the stray token, which silently kills a watcher mid-cycle.
#
#   `[ "$(uname)" = Darwin ]` - uname answers which kernel is running, not
#   which stat is first on PATH. GNU coreutils installed ahead of /usr/bin
#   (Homebrew's coreutils gnubin, nix, MacPorts) makes a Darwin box speak `-c`
#   and read `-f` as that same filesystem dump. That is issue #1601: fleet
#   helpers break on hosts where GNU coreutils shadows BSD stat, so a watcher
#   beacon, a git lock, or an X reply-context record ages wrongly - or not at
#   all - on a machine that merely installed a common toolchain. The same guess
#   also breaks the single-link/0600/same-device artifact checks: those fail
#   CLOSED, but that still turns "installed coreutils" into "X mode and PR
#   check registration refuse every artifact".
#
# So probe the real binary once, on a path that always exists, and bind the
# right form. Every reader then validates its own output and fails (printing
# nothing) unless it is well formed, so a caller can never splice a diagnostic
# dump into arithmetic or into a cache fingerprint. Callers keep their own
# unreadable-value POLICY - a "very old" sentinel where the fail-safe direction
# is "assume abandoned", a hard refusal where it is "never touch it".

if [ -z "${FM_STAT_LIB_SOURCED:-}" ]; then
  FM_STAT_LIB_SOURCED=1

  if stat -c %Y / >/dev/null 2>&1; then
    _fm_stat_mtime_raw() { stat -c %Y "$1" 2>/dev/null; }
    _fm_stat_sig_raw() { stat -c '%s:%Y' "$1" 2>/dev/null; }
    _fm_stat_mode_raw() { stat -c %a "$1" 2>/dev/null; }
    _fm_stat_device_raw() { stat -c %d "$1" 2>/dev/null; }
    _fm_stat_inode_raw() { stat -c %i "$1" 2>/dev/null; }
    _fm_stat_nlink_raw() { stat -c %h "$1" 2>/dev/null; }
    _fm_stat_identity_raw() { LC_ALL=C stat -c '%d:%i:%s:%Y:%Z' "$1" 2>/dev/null; }
  else
    _fm_stat_mtime_raw() { stat -f %m "$1" 2>/dev/null; }
    _fm_stat_sig_raw() { stat -f '%z:%Fm' "$1" 2>/dev/null; }
    _fm_stat_mode_raw() { stat -f %Lp "$1" 2>/dev/null; }
    _fm_stat_device_raw() { stat -f %d "$1" 2>/dev/null; }
    _fm_stat_inode_raw() { stat -f %i "$1" 2>/dev/null; }
    _fm_stat_nlink_raw() { stat -f %l "$1" 2>/dev/null; }
    _fm_stat_identity_raw() { LC_ALL=C stat -f '%d:%i:%z:%m:%c' "$1" 2>/dev/null; }
  fi

  # Print <reader>'s value for <path>, or fail with no output when it is not a
  # plain non-negative integer.
  _fm_stat_integer() {  # <raw-reader> <path>
    local out
    out=$("$1" "$2") || return 1
    case "$out" in
      ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$out"
  }

  # Whole epoch seconds, or non-zero with no output.
  fm_stat_mtime() { _fm_stat_integer _fm_stat_mtime_raw "$1"; }

  # Permission bits in octal (600, 755, ...).
  fm_stat_mode() { _fm_stat_integer _fm_stat_mode_raw "$1"; }

  # Device and inode numbers, and the hard link count. Meaningful only within
  # one host, which is all their callers compare them across.
  fm_stat_device() { _fm_stat_integer _fm_stat_device_raw "$1"; }
  fm_stat_inode() { _fm_stat_integer _fm_stat_inode_raw "$1"; }
  fm_stat_nlink() { _fm_stat_integer _fm_stat_nlink_raw "$1"; }

  # Opaque size:mtime signature for change detection, or non-zero with no
  # output. Compared only for equality, never parsed, so the BSD form's
  # fractional seconds are a free precision win rather than a format contract.
  fm_stat_sig() {
    local out
    out=$(_fm_stat_sig_raw "$1") || return 1
    case "$out" in
      ''|*[!0-9.:]*) return 1 ;;
    esac
    printf '%s\n' "$out"
  }

  # Opaque full-metadata signature (device, inode, size, mtime, ctime), for
  # "did this exact file get replaced or rewritten?". LC_ALL=C is pinned in the
  # raw readers so the value is locale-invariant across the write/read pair.
  fm_stat_identity() {
    local out
    out=$(_fm_stat_identity_raw "$1") || return 1
    case "$out" in
      ''|*[!0-9.:]*) return 1 ;;
    esac
    printf '%s\n' "$out"
  }
fi
