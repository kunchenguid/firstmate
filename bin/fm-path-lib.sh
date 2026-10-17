#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname and small-file helpers with no source-time
# side effects, so read-only callers can load them without any library's state
# setup.
#
# fm_dirname_to and fm_basename_to assign <output-variable> exactly what
# `$(dirname -- <path>)` or `$(basename -- <path>)` would: POSIX component
# rules, and the command substitution's removal of trailing newlines.

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# Assign <output-variable> exactly what `$(cat <file> 2>/dev/null)` would, and
# return the status cat would: 1 with an empty value when the file is missing,
# unreadable, or a directory. NUL bytes are dropped and trailing newlines
# removed, as the command substitution does. FM_READ_FILE_NUL is 1 when the
# file held a NUL byte and 0 otherwise.
# shellcheck disable=SC2034 # FM_READ_FILE_NUL is read by sourcing callers.
FM_READ_FILE_NUL=0
# shellcheck disable=SC2034
fm_read_file_to() {  # <output-variable> <file>
  local fm_chunk='' fm_data=''
  FM_READ_FILE_NUL=0
  if [ -d "$2" ]; then
    printf -v "$1" '%s' ''
    return 1
  fi
  # Bash 3.2 ignores a failed input redirection under `if !`, so test with ||.
  { while IFS= read -r -d '' fm_chunk; do fm_data+=$fm_chunk; FM_READ_FILE_NUL=1; done; fm_data+=$fm_chunk; } 2>/dev/null < "$2" || {
    printf -v "$1" '%s' ''
    return 1
  }
  while [ "${fm_data%$'\n'}" != "$fm_data" ]; do fm_data=${fm_data%$'\n'}; done
  printf -v "$1" '%s' "$fm_data"
}

# True when <text> holds only printable ASCII (space through tilde), judged
# byte by byte. Callers use it to take a pure-bash match only where it cannot
# disagree with the grep or sed it replaces under any locale.
fm_ascii_plain() {  # <text>
  local LC_ALL=C
  case "$1" in
    *[!\ -~]*) return 1 ;;
  esac
  return 0
}
