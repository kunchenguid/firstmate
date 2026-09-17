# shellcheck shell=bash
# Shared home-local config/tools PATH prepend.
# Usage: . bin/fm-tools-path-lib.sh ; fm_tools_path_prepend [<config-dir>]
#
# The optional config/tools helper location documented in docs/configuration.md
# ("Home-local tool PATH (config/tools)") keeps a home's own copies of the
# toolchain out of the global directories: standalone executables in
# <config>/tools/bin and npm-installed package shims in
# <config>/tools/node_modules/.bin.
#
# A launcher that exports those directories covers only the panes it starts, so
# a pane restored or started without it - a Herdr pane on a server started from
# an unlaunched shell, or a hand-opened terminal - sees an ambient PATH without
# them. Bootstrap would then report an installed helper as MISSING and
# lavish-axi as PRESENTATION_UNAVAILABLE, which is false noise for that home.
# This file is the single owner of the directory list and its order.

# fm_tools_path_prepend [<config-dir>]
# Prepend each existing helper directory, in the fixed order
# tools/bin then tools/node_modules/.bin, to PATH and export PATH.
# <config-dir> defaults to FM_CONFIG_OVERRIDE when set, else $FM_HOME/config,
# matching how every other script resolves its config directory.
# A directory that is absent, or whose exact path already appears anywhere in
# PATH, is skipped, so repeated calls are idempotent and a home without
# config/tools is completely unaffected.
fm_tools_path_prepend() {  # [<config-dir>]
  local config=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}}
  local dir prepend=
  for dir in "$config/tools/bin" "$config/tools/node_modules/.bin"; do
    [ -d "$dir" ] || continue
    case ":${PATH:-}:" in
    *":$dir:"*) continue ;;
    esac
    prepend="${prepend:+$prepend:}$dir"
  done
  [ -n "$prepend" ] || return 0
  PATH="$prepend${PATH:+:$PATH}"
  export PATH
}
