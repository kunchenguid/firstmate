# shellcheck shell=bash
# Codex account home resolution: the single owner of how a dispatch profile's
# codexHome (or fm-spawn's --codex-home) becomes the CODEX_HOME a Codex worker
# or a per-account quota read is launched with.
# Usage: . bin/fm-codex-home-lib.sh
#
# A Codex account is a directory holding that account's auth.json; the Codex
# CLI and quota-axi both read it from CODEX_HOME. Firstmate keeps six such
# directories per machine (~/.codex, ~/.codex-1 .. ~/.codex-5), and the
# dispatch profile file that names them is inherited byte-exact into secondmate
# homes on other machines with other users, so a profile spells the home either
# as an absolute path or as a `~/`-prefixed path that expands against the
# LAUNCHING user's $HOME at spawn time - never against the author's.
#
# fm_codex_home_expand <path>
#   Sets FM_CODEX_HOME_PATH to the expanded absolute path. `~/...` expands
#   against $HOME; an absolute path is kept unchanged. Anything else (bare
#   `~`, relative, empty, or a `~user/` form) fails, as does expansion when
#   $HOME is unset or relative.
# fm_codex_home_validate <path>
#   Expands, then requires the directory to exist and to hold a non-empty
#   regular auth.json, and sets FM_CODEX_HOME_PATH on success. The check reads
#   the file's size only, never its contents.
# Both return 1 with FM_CODEX_HOME_ERROR set to a one-line reason on failure,
# so a caller refuses loudly instead of falling back to the default account.
# Results travel in variables rather than stdout so a caller keeps the reason
# without a subshell swallowing it.

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_CODEX_HOME_ERROR=
FM_CODEX_HOME_PATH=

fm_codex_home_expand() {
  local path=${1:-} home
  FM_CODEX_HOME_ERROR=
  FM_CODEX_HOME_PATH=
  # shellcheck disable=SC2088 # the literal ~ and ~/ spellings are the patterns being matched
  case "$path" in
    '')
      FM_CODEX_HOME_ERROR="codex home is empty"
      return 1
      ;;
    '~/'*)
      home=${HOME:-}
      case "$home" in
        /*) ;;
        *)
          FM_CODEX_HOME_ERROR="codex home '$path' needs an absolute \$HOME to expand against (HOME='${home}')"
          return 1
          ;;
      esac
      path="$home/${path#\~/}"
      ;;
    /*) ;;
    *)
      FM_CODEX_HOME_ERROR="codex home '$path' must be an absolute path or start with ~/"
      return 1
      ;;
  esac
  FM_CODEX_HOME_PATH=$path
}

fm_codex_home_validate() {
  local path
  fm_codex_home_expand "${1:-}" || return 1
  path=$FM_CODEX_HOME_PATH
  FM_CODEX_HOME_PATH=
  if [ ! -d "$path" ]; then
    FM_CODEX_HOME_ERROR="codex home '$path' is not a directory"
    return 1
  fi
  if [ ! -f "$path/auth.json" ] || [ ! -s "$path/auth.json" ]; then
    FM_CODEX_HOME_ERROR="codex home '$path' has no non-empty auth.json; sign that account in with CODEX_HOME='$path' codex login before dispatching on it"
    return 1
  fi
  FM_CODEX_HOME_PATH=$path
}
