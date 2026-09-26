#!/usr/bin/env bash
# fm-hermes-plugin.sh - install, inspect, and remove the Firstmate Hermes plugin.
#
# Hermes Agent loads only plugins that are both discovered and named in its
# `plugins.enabled` config list (hermes_cli/plugins_discovery.py gate_manifest,
# verified v0.21.5). A Hermes worker runs in a PROJECT worktree, where the
# project rather than Firstmate owns `.hermes/`, so Firstmate's loader must
# live in the Hermes home to reach workers at all. This script owns that one
# install surface:
#
#   $HERMES_HOME/plugins/firstmate/plugin.yaml   byte copies of the tracked loader
#   $HERMES_HOME/plugins/firstmate/__init__.py   in .hermes/plugins/firstmate/
#   $HERMES_HOME/plugins/firstmate/roots         absolute Firstmate roots whose
#                                                primary sessions may load it
#
# The installed loader carries no behaviour of its own: it resolves which
# Firstmate checkout to load and imports that checkout's tracked
# .hermes/firstmate/plugin.py, so /updatefirstmate updates behaviour without a
# reinstall. Only a changed loader (LOADER_VERSION) needs `install` again, and
# `status` reports that as `stale`.
#
# Enabling and the TUI injection grant go through Hermes's own supported
# commands (`hermes plugins enable firstmate`, `hermes config set ...`), never
# a hand edit of config.yaml. Installing is an outward write to the captain's
# Hermes home, so bootstrap only DETECTS a missing or stale install and asks
# (docs/configuration.md "Hermes plugin"); nothing calls `install` unprompted.
#
# Usage:
#   fm-hermes-plugin.sh status [--root <firstmate-root>] [--quiet]
#       Print one state word and exit 0 only for `ok`:
#         ok            loader installed, current, enabled, and this root registered
#         no-hermes     no `hermes` executable on PATH
#         missing       loader not installed in the Hermes home
#         stale         installed loader differs from this checkout's tracked copy
#         disabled      loader installed but `firstmate` is not in plugins.enabled
#         unregistered  loader installed and enabled, but this root is not in `roots`
#                       (workers and FM_HERMES_ROOT launches still work; a
#                       hand-started primary in this home does not load it)
#         unknown       the enabled list could not be read (Hermes errored or timed out)
#   fm-hermes-plugin.sh install [--root <firstmate-root>] [--no-enable]
#       Copy the loader, register the root, enable the plugin, and grant the
#       Ink TUI/desktop injection the watcher needs there. Idempotent.
#   fm-hermes-plugin.sh unregister [--root <firstmate-root>]
#       Remove one root from `roots`; the loader stays for other roots and workers.
#   fm-hermes-plugin.sh uninstall
#       `hermes plugins disable firstmate` and remove the installed loader.
#
# Environment: HERMES_HOME (default ~/.hermes), FM_HERMES_BIN (default `hermes`),
# FM_HERMES_CONFIG_TIMEOUT seconds for each Hermes CLI call (default 30).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_BIN=${FM_HERMES_BIN:-hermes}
HERMES_HOME_DIR=${HERMES_HOME:-$HOME/.hermes}
TIMEOUT=${FM_HERMES_CONFIG_TIMEOUT:-30}
PLUGIN_NAME=firstmate
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Environment:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

CMD=${1:-}
[ -n "$CMD" ] || usage
shift
QUIET=0
ENABLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT=${2:-}; shift 2 || usage ;;
    --root=*) ROOT=${1#--root=}; shift ;;
    --quiet) QUIET=1; shift ;;
    --no-enable) ENABLE=0; shift ;;
    *) usage ;;
  esac
done
case "$ROOT" in /*) ;; *) echo "error: --root must be absolute" >&2; exit 2 ;; esac
ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) || { echo "error: root not found" >&2; exit 2; }

SRC="$ROOT/.hermes/plugins/$PLUGIN_NAME"
DEST="$HERMES_HOME_DIR/plugins/$PLUGIN_NAME"
ROOTS="$DEST/roots"

hermes_available() { command -v "$HERMES_BIN" >/dev/null 2>&1; }

hermes_cli() {  # <args...>
  fm_run_timed "$TIMEOUT" "$HERMES_BIN" "$@"
}

loader_current() {
  [ -f "$DEST/__init__.py" ] && [ -f "$DEST/plugin.yaml" ] || return 1
  cmp -s "$SRC/__init__.py" "$DEST/__init__.py" && cmp -s "$SRC/plugin.yaml" "$DEST/plugin.yaml"
}

root_registered() {
  [ -f "$ROOTS" ] || return 1
  grep -Fxq -- "$ROOT" "$ROOTS"
}

# Print yes|no|unknown for whether `firstmate` is in plugins.enabled.
plugin_enabled() {
  local out
  out=$(hermes_cli config get plugins.enabled 2>/dev/null) || { printf 'unknown'; return; }
  if printf '%s\n' "$out" | grep -Eq "^[[:space:]]*-[[:space:]]*['\"]?${PLUGIN_NAME}['\"]?[[:space:]]*\$"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

status_word() {
  hermes_available || { printf 'no-hermes'; return; }
  [ -f "$DEST/__init__.py" ] || { printf 'missing'; return; }
  loader_current || { printf 'stale'; return; }
  case "$(plugin_enabled)" in
    yes) ;;
    no) printf 'disabled'; return ;;
    *) printf 'unknown'; return ;;
  esac
  root_registered || { printf 'unregistered'; return; }
  printf 'ok'
}

register_root() {
  mkdir -p "$DEST" || return 1
  root_registered && return 0
  printf '%s\n' "$ROOT" >> "$ROOTS"
}

case "$CMD" in
  status)
    word=$(status_word)
    [ "$QUIET" = 1 ] || printf '%s\n' "$word"
    [ "$word" = ok ]
    ;;
  install)
    hermes_available || { echo "error: no '$HERMES_BIN' executable on PATH; install Hermes Agent first" >&2; exit 1; }
    [ -f "$SRC/__init__.py" ] && [ -f "$SRC/plugin.yaml" ] || { echo "error: tracked loader missing under $SRC" >&2; exit 1; }
    mkdir -p "$DEST" || { echo "error: cannot create $DEST" >&2; exit 1; }
    for f in __init__.py plugin.yaml; do
      tmp="$DEST/.$f.tmp.$$"
      if ! { cp "$SRC/$f" "$tmp" && mv -f "$tmp" "$DEST/$f"; }; then
        rm -f "$tmp"
        echo "error: cannot install $f" >&2
        exit 1
      fi
    done
    register_root || { echo "error: cannot register $ROOT in $ROOTS" >&2; exit 1; }
    echo "installed Firstmate Hermes loader at $DEST (root registered: $ROOT)"
    if [ "$ENABLE" = 1 ]; then
      if hermes_cli plugins enable "$PLUGIN_NAME" >/dev/null 2>&1; then
        echo "enabled: hermes plugins enable $PLUGIN_NAME"
      else
        echo "warning: 'hermes plugins enable $PLUGIN_NAME' failed; run it yourself" >&2
      fi
      # The classic CLI injects without any grant; the Ink TUI and desktop hosts
      # refuse plugin injection unless this per-plugin grant is set.
      if hermes_cli config set "plugins.entries.$PLUGIN_NAME.allow_gateway_injection" true >/dev/null 2>&1; then
        echo "granted: plugins.entries.$PLUGIN_NAME.allow_gateway_injection=true"
      else
        echo "warning: could not grant TUI injection; watcher wakes in the TUI then ride the next turn" >&2
      fi
    fi
    word=$(status_word)
    echo "status: $word"
    [ "$word" = ok ] || [ "$ENABLE" = 0 ]
    ;;
  unregister)
    [ -f "$ROOTS" ] || exit 0
    tmp="$ROOTS.tmp.$$"
    grep -Fxv -- "$ROOT" "$ROOTS" > "$tmp" || true
    mv -f "$tmp" "$ROOTS"
    echo "unregistered $ROOT"
    ;;
  uninstall)
    if hermes_available; then
      hermes_cli plugins disable "$PLUGIN_NAME" >/dev/null 2>&1 || true
    fi
    if [ -d "$DEST" ]; then
      rm -f "$DEST/__init__.py" "$DEST/plugin.yaml" "$DEST/roots"
      rm -rf "$DEST/__pycache__"
      rmdir "$DEST" 2>/dev/null || true
    fi
    echo "uninstalled Firstmate Hermes loader from $DEST"
    ;;
  *) usage ;;
esac
