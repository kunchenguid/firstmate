#!/usr/bin/env bash
# fm-rex-palette.sh - install or remove Firstmate's Rex command-palette actions.
#
# docs/rex-backend.md "Command palette" owns the public contract, including
# that installing needs the captain's word because it edits their Rex
# init.lua and reloads every connected client's keymap. This header owns the
# mechanics.
#
# Usage:
#   fm-rex-palette.sh install [--server <unix://...>]
#   fm-rex-palette.sh uninstall [--server <unix://...>]
#
# The server is --server, else FM_REX_SERVER, else REX_SERVER (set inside a
# Rex pane), else the default local Rex server; it must be a local unix://
# server, because Rex reloads its config only over the local socket. The file
# is the one that server reports (`rex keymap --json` .config.path, which
# honors a server-side REX_CONFIG); a symlink's target is edited in place.
#
# Firstmate owns only the lines from the exact begin marker line to the exact
# end marker line below, and refuses a file with unbalanced or repeated
# markers. A new block goes at the TOP of the file, so anything the captain
# defines after it wins (Rex keeps the later definition). install on an
# installed file replaces the block where it is. The block loads
# bin/backends/rex-palette.lua inside pcall; when that fails, a
# `fm_load_error` palette entry shows why, and the captain's own config
# still loads. The block records this checkout's root, FM_HOME, the caller's
# PATH (an app-started Rex server runs with a minimal PATH), and the server
# unless it came from default discovery. When install creates the file, the
# block carries a created marker, and uninstall deletes the file again if
# nothing else is left in it.
#
# Each write builds the new file next to the old one, requires `rex config
# check` to pass on it, copies the old file to <file>.fm-backup.<UTC stamp>,
# keeps its permission bits, renames the new file over it, and then runs
# `rex config reload`. install on a file that already holds this exact block
# writes nothing but still reloads, so a rerun after a failed reload loads it.
# uninstall removes exactly the block's lines, so the rest of the file stays
# byte-for-byte what it was.
#
# Exit status: 0 on success (including nothing to do), 1 on a refusal or a
# failed step, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

BEGIN_MARK='-- >>> firstmate palette >>>'
END_MARK='-- <<< firstmate palette <<<'
CREATED_MARK='-- firstmate created this file'

die() {
  printf 'fm-rex-palette: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '9,11p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

SERVER=
EXPLICIT_SERVER=0
resolve_server() {
  fm_backend_source rex >/dev/null 2>&1 || die "Rex support is not available in this Firstmate copy"
  fm_backend_rex_tool_check || exit 1
  if [ -z "$SERVER" ]; then
    SERVER=$(fm_backend_rex_server) || die "no running Rex server was found"
  else
    EXPLICIT_SERVER=1
  fi
  case "$SERVER" in
    unix://?*) ;;
    *) die "refusing $SERVER: the palette installs only on this machine's own Rex server (unix://)" ;;
  esac
}

rex_s() {
  FM_BACKEND_REX_SERVER=$SERVER fm_backend_rex_cli "$@"
}

CONFIG=
resolve_config() {
  local out path hops=0 link
  out=$(rex_s keymap --json 2>/dev/null) || die "cannot read the config path from Rex server $SERVER"
  path=$(printf '%s' "$out" | jq -r '.config.path // empty' 2>/dev/null)
  case "$path" in /*) ;; *) die "Rex server $SERVER reported no usable config path" ;; esac
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 16 ] || die "too many symlinks at $path"
    link=$(readlink "$path") || die "cannot read symlink $path"
    case "$link" in /*) path=$link ;; *) path="$(dirname "$path")/$link" ;; esac
  done
  CONFIG=$path
}

# Line numbers of the markers; refuses unbalanced or repeated ones.
B_LINE=
E_LINE=
find_block() {
  local begins ends nb ne
  B_LINE=
  E_LINE=
  [ -f "$CONFIG" ] || return 0
  begins=$(grep -n -x -F -- "$BEGIN_MARK" "$CONFIG" | cut -d: -f1)
  ends=$(grep -n -x -F -- "$END_MARK" "$CONFIG" | cut -d: -f1)
  nb=$(printf '%s' "$begins" | grep -c .)
  ne=$(printf '%s' "$ends" | grep -c .)
  if [ "$nb" -gt 1 ] || [ "$nb" != "$ne" ]; then
    die "refusing: $CONFIG has $nb begin and $ne end Firstmate marker lines; fix it by hand"
  fi
  [ "$nb" = 1 ] || return 0
  [ "$begins" -lt "$ends" ] || die "refusing: the Firstmate end marker comes before its begin marker in $CONFIG"
  B_LINE=$begins
  E_LINE=$ends
}

# A Lua double-quoted string literal.
lua_str() {
  case "$1" in *$'\n'* | *$'\r'*) die "refusing a value with a line break: $1" ;; esac
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

render_block() { # <created:0|1>
  local server_field=''
  [ "$EXPLICIT_SERVER" = 0 ] || server_field=", server = $(lua_str "$SERVER")"
  printf '%s\n' "$BEGIN_MARK"
  printf '%s\n' "-- Managed by Firstmate's bin/fm-rex-palette.sh: install replaces these lines and uninstall removes them."
  [ "$1" = 0 ] || printf '%s\n' "$CREATED_MARK"
  printf 'do\n'
  printf '  local ok, err = pcall(function()\n'
  printf '    dofile(%s).setup{ root = %s, home = %s, path = %s%s }\n' \
    "$(lua_str "$FM_ROOT/bin/backends/rex-palette.lua")" "$(lua_str "$FM_ROOT")" "$(lua_str "$FM_HOME")" \
    "$(lua_str "$PATH")" "$server_field"
  printf '  end)\n'
  printf '  if not ok then\n'
  printf '    local why = "Firstmate palette not loaded: " .. tostring(err)\n'
  printf '    rex.log("warn", why)\n'
  printf '    rex.action{ name = "fm_load_error", title = "Firstmate: Palette Failed to Load", category = "Firstmate",\n'
  printf '      description = why, run = function() error(why, 0) end }\n'
  printf '  end\n'
  printf 'end\n'
  printf '%s\n' "$END_MARK"
}

# Writes the would-be installed file to <out>.
# The first <n> lines of the config, byte for byte (BSD head refuses -n 0).
lines_before() { # <n>
  [ "$1" -le 0 ] || head -n "$1" "$CONFIG"
}

build_installed() { # <out>
  local out=$1 created=0
  if [ ! -e "$CONFIG" ]; then
    render_block 1 >"$out"
    return
  fi
  if [ -z "$B_LINE" ]; then
    { render_block 0; cat "$CONFIG"; } >"$out"
    return
  fi
  sed -n "${B_LINE},${E_LINE}p" "$CONFIG" | grep -q -x -F -- "$CREATED_MARK" && created=1
  { lines_before $((B_LINE - 1)); render_block "$created"; tail -n +$((E_LINE + 1)) "$CONFIG"; } >"$out"
}

build_removed() { # <out>
  { lines_before $((B_LINE - 1)); tail -n +$((E_LINE + 1)) "$CONFIG"; } >"$1"
}

file_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}

config_check() { # <file>
  local out
  out=$(rex_s config check "$1" 2>&1) && return 0
  printf '%s\n' "$out" >&2
  return 1
}

backup() {
  local dest
  [ -e "$CONFIG" ] || return 0
  dest="$CONFIG.fm-backup.$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$dest" ] || dest="$dest.$$"
  cp -p "$CONFIG" "$dest" || die "could not back up $CONFIG"
  printf 'backup: %s\n' "$dest"
}

replace_with() { # <new-file>
  local new=$1
  if [ -e "$CONFIG" ]; then
    chmod "$(file_mode "$CONFIG")" "$new" 2>/dev/null || true
  fi
  mv -f "$new" "$CONFIG" || die "could not replace $CONFIG"
}

reload() {
  local out
  if out=$(rex_s config reload 2>&1); then
    printf 'reloaded: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"
  else
    printf '%s\n' "$out" >&2
    die "the file was written, but rex config reload failed; run \`rex -S $SERVER config reload\` once the server is reachable"
  fi
}

tmp_beside() {
  local dir
  dir=$(dirname "$CONFIG")
  mkdir -p "$dir" || die "cannot create $dir"
  mktemp "$dir/.init.lua.fm-palette.XXXXXX" || die "cannot create a temp file in $dir"
}

cmd_install() {
  local new
  find_block
  new=$(tmp_beside)
  build_installed "$new"
  if [ -f "$CONFIG" ] && cmp -s "$new" "$CONFIG"; then
    rm -f "$new"
    printf 'unchanged: %s already has this palette block\n' "$CONFIG"
    reload
    return 0
  fi
  config_check "$new" || { rm -f "$new"; die "rex config check failed on the new $CONFIG; nothing was written"; }
  backup
  replace_with "$new"
  printf 'installed: %s\n' "$CONFIG"
  reload
}

cmd_uninstall() {
  local new created=0
  find_block
  if [ -z "$B_LINE" ]; then
    printf 'not installed: %s has no Firstmate palette block\n' "$CONFIG"
    return 0
  fi
  sed -n "${B_LINE},${E_LINE}p" "$CONFIG" | grep -q -x -F -- "$CREATED_MARK" && created=1
  new=$(tmp_beside)
  build_removed "$new"
  backup
  if [ "$created" = 1 ] && [ ! -s "$new" ]; then
    rm -f "$new" "$CONFIG"
    printf 'removed: %s (Firstmate had created it)\n' "$CONFIG"
  else
    replace_with "$new"
    printf 'uninstalled: %s\n' "$CONFIG"
  fi
  reload
}

main() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server) [ "$#" -ge 2 ] || usage; SERVER=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$cmd" in
    install | uninstall) ;;
    -h | --help | help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) usage ;;
  esac
  [ -n "$SERVER" ] || SERVER=${FM_REX_SERVER:-${REX_SERVER:-}}
  resolve_server
  resolve_config
  "cmd_$cmd"
}

main "$@"
