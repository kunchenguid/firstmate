#!/usr/bin/env bash
# Terminal-multiplexer abstraction for firstmate.
#
# firstmate's crew lives in multiplexer windows. tmux has no Windows port, so
# this library hides the multiplexer behind a small verb set with two backends:
#   tmux     - macOS / Linux (and anywhere tmux is installed). The tmux backend
#              issues exactly the tmux commands the scripts used before this
#              library existed, so existing behavior and the test shims are
#              unchanged.
#   wezterm  - native Windows (and anywhere WezTerm's multiplexer CLI is the
#              chosen backend). Crewmates appear as WezTerm tabs you can watch.
#
# SOURCE it (`. fm-mux.sh`) to call the fm_mux_* functions, or run it as a CLI
# (`fm-mux.sh <verb> [args...]`) for ad-hoc use and tests.
#
# WINDOW HANDLE. Every verb that targets a window takes an opaque handle and
# every creator prints one; callers store it verbatim (e.g. in state/<id>.meta
# `window=`). The two backends use different handle shapes, distinguished by a
# `wezterm:` prefix so a single helper can dispatch:
#   tmux     "<session>:<window>"   e.g. firstmate:fm-fix-k3   (legacy shape)
#   wezterm  "wezterm:<pane_id>"    e.g. wezterm:14
#
# BACKEND SELECTION (fm_mux_backend, cached in FM_MUX_BACKEND):
#   1. $FM_MUX               explicit override (tmux|wezterm)
#   2. $TMUX set            -> tmux  (we are running inside tmux)
#   3. tmux on PATH         -> tmux  (prefer tmux where present; keeps the test
#                                     shims and macOS/Linux default intact, and
#                                     keeps wezterm-on-mac users on tmux unless
#                                     they set FM_MUX=wezterm)
#   4. WEZTERM_PANE + wezterm on PATH -> wezterm
#   5. wezterm on PATH      -> wezterm
#   6. none                 (no multiplexer; verbs fail loudly)

_FM_WEZ="${FM_WEZTERM:-wezterm}"

fm_mux_backend() {
  if [ -n "${FM_MUX_BACKEND:-}" ]; then printf '%s' "$FM_MUX_BACKEND"; return 0; fi
  local b
  if [ -n "${FM_MUX:-}" ]; then
    b=$FM_MUX
  elif [ -n "${TMUX:-}" ]; then
    b=tmux
  elif command -v tmux >/dev/null 2>&1; then
    b=tmux
  elif command -v "$_FM_WEZ" >/dev/null 2>&1; then
    b=wezterm
  else
    b=none
  fi
  FM_MUX_BACKEND=$b
  printf '%s' "$b"
}

_fm_mux_no_backend() {
  echo "error: no terminal multiplexer available (need tmux or wezterm); set FM_MUX" >&2
  return 1
}

# --- wezterm helpers --------------------------------------------------------

# Strip the "wezterm:" prefix from a handle to get the bare pane id.
_fm_wez_pane() { printf '%s' "${1#wezterm:}"; }

# Print one TAB-separated record per pane: pane_id<TAB>title<TAB>cwd<TAB>cursor_x<TAB>cursor_y
# Parsed from `wezterm cli list --format json` with perl (always present under
# Git Bash) so we avoid a jq dependency. wezterm emits one flat object per pane
# with a single nested "size" object whose keys never collide with the fields
# below, so a line-oriented parser is reliable.
_fm_wez_list() {
  "$_FM_WEZ" cli list --format json 2>/dev/null | perl -ne '
    sub flush { print "$p\t$ti\t$cw\t$cx\t$cy\n" if defined $p; }
    if (/"pane_id":\s*(\d+)/)   { flush(); $p=$1; $ti=""; $cw=""; $cx=""; $cy=""; }
    elsif (/"title":\s*"(.*?)"/)    { $ti=$1; }
    elsif (/"cwd":\s*"(.*?)"/)      { $cw=$1; }
    elsif (/"cursor_x":\s*(\d+)/)   { $cx=$1; }
    elsif (/"cursor_y":\s*(\d+)/)   { $cy=$1; }
    END { flush(); }
  '
}

# Print field N (1=pane_id 2=title 3=cwd 4=cursor_x 5=cursor_y) for a pane id.
_fm_wez_field() {
  local pane=$1 field=$2
  _fm_wez_list | awk -F '\t' -v p="$pane" -v f="$field" '$1==p {print $f; exit}'
}

# Convert a wezterm file:// cwd URI to the same path shape `pwd` prints, so
# callers can compare it against an MSYS/absolute path. URL-decodes, then routes
# a Windows path through cygpath -u (Git Bash) to yield e.g. /c/projects/foo.
_fm_wez_uri_to_path() {
  local uri=$1 p
  case "$uri" in
    file://*) p=${uri#file://} ;;   # file:///C:/x -> /C:/x  (empty host)
    *) printf '%s' "$uri"; return 0 ;;
  esac
  if command -v perl >/dev/null 2>&1; then
    p=$(printf '%s' "$p" | perl -pe 's/%([0-9A-Fa-f]{2})/chr(hex($1))/ge')
  fi
  if command -v cygpath >/dev/null 2>&1; then
    case "$p" in /[A-Za-z]:/*) p=${p#/} ;; esac   # /C:/x -> C:/x for cygpath
    p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p")
  fi
  # wezterm's cwd URI keeps a trailing slash (file:///C:/x/); `pwd` does not, so
  # drop one trailing slash (but never reduce the root "/" to empty) to make the
  # value comparable to a known path.
  case "$p" in
    /) ;;
    */) p=${p%/} ;;
  esac
  printf '%s' "$p"
}

# Translate a tmux-style key name to the bytes wezterm should inject.
_fm_wez_key_bytes() {
  case "$1" in
    Enter) printf '\r' ;;
    Escape) printf '\033' ;;
    C-c) printf '\003' ;;
    C-d) printf '\004' ;;
    C-z) printf '\032' ;;
    Space) printf ' ' ;;
    Tab) printf '\t' ;;
    BSpace) printf '\177' ;;
    *) printf '%s' "$1" ;;   # last resort: inject the literal name
  esac
}

# Send raw text to a wezterm pane's input via stdin (preserves quotes, $(),
# and other metacharacters that argv conversion across the MSYS->Windows
# boundary would otherwise mangle).
_fm_wez_send() {
  local pane=$1 text=$2
  printf '%s' "$text" | "$_FM_WEZ" cli send-text --pane-id "$pane" --no-paste
}

# --- verbs ------------------------------------------------------------------

# Print the opaque session token to create windows in. For tmux this is the
# current session when inside tmux, otherwise a dedicated detached `firstmate`
# session (created if absent). wezterm has no separate session object - new
# tabs land in the active window - so it returns a constant sentinel.
fm_mux_session() {
  case "$(fm_mux_backend)" in
    tmux)
      if [ -n "${TMUX:-}" ]; then
        tmux display-message -p '#S'
      else
        tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
        printf '%s' firstmate
      fi
      ;;
    wezterm) printf '%s' wezterm ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Does a window named <name> already exist in <session>? Exit 0 if yes.
# wezterm cannot be queried by window name (set-tab-title is not reflected in
# `cli list`, and input injection cannot set a queryable pane title), so it
# always reports "not found"; firstmate guarantees unique task ids, and every
# live task is tracked by its handle in state/<id>.meta.
fm_mux_window_exists() {
  local ses=$1 name=$2
  case "$(fm_mux_backend)" in
    tmux) tmux list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qx "$name" ;;
    wezterm) return 1 ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Create a window/tab named <name> running an interactive shell in <cwd>.
# Prints the handle to store. The shell is the caller's default shell under
# tmux; under wezterm it is an interactive login Git Bash, so the bash-syntax
# launch command firstmate sends next is understood on Windows.
fm_mux_new_window() {
  local ses=$1 name=$2 cwd=$3
  case "$(fm_mux_backend)" in
    tmux)
      tmux new-window -d -t "$ses" -n "$name" -c "$cwd"
      printf '%s:%s' "$ses" "$name"
      ;;
    wezterm)
      local wincwd pane shell
      wincwd=$cwd
      if command -v cygpath >/dev/null 2>&1; then
        wincwd=$(cygpath -w "$cwd" 2>/dev/null || printf '%s' "$cwd")
      fi
      shell="${FM_MUX_WEZTERM_SHELL:-$(command -v bash || printf '%s' bash)}"
      pane=$("$_FM_WEZ" cli spawn --cwd "$wincwd" -- "$shell" --login -i) || return 1
      [ -n "$pane" ] || return 1
      "$_FM_WEZ" cli set-tab-title --pane-id "$pane" "$name" >/dev/null 2>&1 || true
      printf 'wezterm:%s' "$pane"
      ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Send literal text to a window's input (no trailing Enter).
fm_mux_send_text() {
  local handle=$1 text=$2
  case "$(fm_mux_backend)" in
    tmux) tmux send-keys -t "$handle" -l "$text" ;;
    wezterm) _fm_wez_send "$(_fm_wez_pane "$handle")" "$text" ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Submit the current input line (press Enter).
fm_mux_send_enter() {
  local handle=$1
  case "$(fm_mux_backend)" in
    tmux) tmux send-keys -t "$handle" Enter ;;
    wezterm) _fm_wez_send "$(_fm_wez_pane "$handle")" "$(printf '\r')" ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Send a named special key (Enter, Escape, C-c, ...) to a window.
fm_mux_send_key() {
  local handle=$1 key=$2
  case "$(fm_mux_backend)" in
    tmux) tmux send-keys -t "$handle" "$key" ;;
    wezterm) _fm_wez_send "$(_fm_wez_pane "$handle")" "$(_fm_wez_key_bytes "$key")" ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Print the window's current working directory (pane_current_path), normalized
# to the local `pwd` shape so callers can compare it against a known path.
fm_mux_pane_path() {
  local handle=$1
  case "$(fm_mux_backend)" in
    tmux) tmux display-message -p -t "$handle" '#{pane_current_path}' 2>/dev/null ;;
    wezterm)
      local cw
      cw=$(_fm_wez_field "$(_fm_wez_pane "$handle")" 3) || return 1
      [ -n "$cw" ] || return 1
      _fm_wez_uri_to_path "$cw"
      ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Print the last <lines> lines of a window's pane (default 40).
fm_mux_capture() {
  local handle=$1 lines=${2:-40}
  case "$(fm_mux_backend)" in
    tmux) tmux capture-pane -p -t "$handle" -S -"$lines" ;;
    wezterm)
      # get-text returns the whole viewport, including the blank rows below the
      # content (tmux's -S -N does not). Trim trailing blank lines before
      # tailing so "last N lines" means N lines of actual content, matching the
      # tmux backend - important for stable staleness hashing in fm-watch.
      # Capture to a variable first so a dead pane (get-text non-zero) propagates
      # as a non-zero return, like capture-pane on a missing tmux pane.
      local out
      out=$("$_FM_WEZ" cli get-text --pane-id "$(_fm_wez_pane "$handle")" 2>/dev/null) || return 1
      printf '%s\n' "$out" \
        | awk '{ a[NR]=$0 } END { n=NR; while (n>0 && a[n] ~ /^[[:space:]]*$/) n--; for (i=1;i<=n;i++) print a[i] }' \
        | tail -n "$lines"
      ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Print the full visible pane (no trailing-blank trim) so the row at index
# cursor_y lines up with this output - the sub-supervisor's pane_input_pending
# reads the cursor line by number. Distinct from fm_mux_capture, which trims and
# tails for "last N lines of content".
fm_mux_capture_visible() {
  local handle=$1
  case "$(fm_mux_backend)" in
    tmux) tmux capture-pane -p -t "$handle" ;;
    wezterm) "$_FM_WEZ" cli get-text --pane-id "$(_fm_wez_pane "$handle")" 2>/dev/null || return 1 ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Print the cursor's 0-indexed row within the visible pane (for input-pending
# detection in the sub-supervisor).
fm_mux_cursor_y() {
  local handle=$1
  case "$(fm_mux_backend)" in
    tmux) tmux display-message -p -t "$handle" '#{cursor_y}' 2>/dev/null ;;
    wezterm) _fm_wez_field "$(_fm_wez_pane "$handle")" 5 ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Exit 0 if the window's pane still exists.
fm_mux_pane_alive() {
  local handle=$1
  case "$(fm_mux_backend)" in
    tmux) tmux display-message -p -t "$handle" '#{pane_id}' >/dev/null 2>&1 ;;
    wezterm)
      local pane found
      pane=$(_fm_wez_pane "$handle")
      found=$(_fm_wez_field "$pane" 1)
      [ "$found" = "$pane" ]
      ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Kill a window (and its pane).
fm_mux_kill_window() {
  local handle=$1
  case "$(fm_mux_backend)" in
    tmux) tmux kill-window -t "$handle" 2>/dev/null || true ;;
    wezterm) "$_FM_WEZ" cli kill-pane --pane-id "$(_fm_wez_pane "$handle")" >/dev/null 2>&1 || true ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Resolve a bare window name to a handle (the rare path where a caller targets a
# window not tracked by this home's meta). tmux searches all sessions; wezterm
# cannot match by name (see fm_mux_window_exists) and fails - use fm-<id> (which
# resolves through meta) or pass the handle directly.
fm_mux_find_window() {
  local name=$1
  case "$(fm_mux_backend)" in
    tmux) tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -m1 ":$name\$" ;;
    wezterm)
      echo "error: wezterm backend cannot resolve a window by bare name; use fm-<id> or pass the wezterm:<pane_id> handle" >&2
      return 1
      ;;
    *) _fm_mux_no_backend ;;
  esac
}

# Print the handle of the pane firstmate itself is running in (the sub-supervisor
# injects escalations here). Honors FM_SUPERVISOR_TARGET, then the in-pane env
# var each multiplexer exports, then a backend fallback.
fm_mux_resolve_supervisor() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then printf '%s' "$FM_SUPERVISOR_TARGET"; return 0; fi
  case "$(fm_mux_backend)" in
    tmux)
      if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; else printf '%s' "${FM_SUPERVISOR_TARGET_DEFAULT:-firstmate:0}"; return 1; fi
      ;;
    wezterm)
      if [ -n "${WEZTERM_PANE:-}" ]; then printf 'wezterm:%s' "$WEZTERM_PANE"; else return 1; fi
      ;;
    *) _fm_mux_no_backend ;;
  esac
}

# CLI dispatcher (only when executed, not sourced) so verbs are usable by hand
# and from tests: fm-mux.sh <verb-without-fm_mux_-prefix> [args...]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  verb=${1:-}
  [ -n "$verb" ] || { echo "usage: fm-mux.sh <backend|session|window-exists|new-window|send-text|send-enter|send-key|pane-path|capture|cursor-y|pane-alive|kill-window|find-window|resolve-supervisor> [args...]" >&2; exit 2; }
  shift || true
  case "$verb" in
    backend) fm_mux_backend; echo ;;
    session) fm_mux_session ;;
    window-exists) fm_mux_window_exists "$@" ;;
    new-window) fm_mux_new_window "$@" ;;
    send-text) fm_mux_send_text "$@" ;;
    send-enter) fm_mux_send_enter "$@" ;;
    send-key) fm_mux_send_key "$@" ;;
    pane-path) fm_mux_pane_path "$@" ;;
    capture) fm_mux_capture "$@" ;;
    capture-visible) fm_mux_capture_visible "$@" ;;
    cursor-y) fm_mux_cursor_y "$@" ;;
    pane-alive) fm_mux_pane_alive "$@" ;;
    kill-window) fm_mux_kill_window "$@" ;;
    find-window) fm_mux_find_window "$@" ;;
    resolve-supervisor) fm_mux_resolve_supervisor "$@" ;;
    *) echo "error: unknown verb $verb" >&2; exit 2 ;;
  esac
fi
