#!/usr/bin/env bash
# fm-notify.sh - firstmate's native out-of-band notifier (firstmate issue #106).
#
# Fires a native OS notification so the captain gets pinged out of band the moment
# firstmate escalates a decision while they are away from the pane. This is the
# FIRST backend of the pluggable notifier from issue #106; the pluggable seam for
# a later remote-push backend (a phone push via ntfy or Pushover) is marked below.
#
# Usage: fm-notify.sh "<title>" "<message>" [--focus|--no-focus] [--open <url>]
#        fm-notify.sh install            # arm click-to-focus (WSL only)
#   --focus     (DEFAULT) make the toast carry a "Go to firstmate" action that
#               focuses the host terminal and the firstmate pane WHEN THE CAPTAIN
#               CLICKS it. Click-to-focus, never auto-focus - see below.
#   --no-focus  opt out of the click-to-focus action (used by tests; the default
#               is always focus-on so a bare call still gets the full toast).
#   --open <url>  add a SECOND "Open PR" action that opens <url> in the default
#               browser when clicked. Used for done-state escalations that carry a
#               PR/MR URL, so the captain can jump straight to the PR. Windows gets
#               a real second toast button (activationType="protocol"); macOS and
#               Linux are best-effort (terminal-notifier -open / notify-send
#               --action). Omitted -> no extra button (unchanged behavior).
#
# Contract: dependency-free beyond the platform's own tools, fast, and
# non-blocking. The notifier never hangs the caller and never fails it: if no
# backend is reachable on this platform it exits 0 quietly, and the actual
# dispatch is backgrounded so a slow host call (PowerShell startup) cannot stall
# whatever called it.
#
# Toggle: FM_NOTIFY (default on). FM_NOTIFY=off (also 0/false/no/disabled)
# silences every notification.
#
# ALWAYS-ON PERSISTENT, SOUNDING, CLICK-TO-FOCUS toast (the captain's chosen
# design). Every toast pops as a banner, plays a sound, and stays until acted on,
# instead of dropping silently into the notification center - the failure the
# captain hit when a toast fired without the focus action. Focus is ON BY DEFAULT
# for exactly this reason; a bare `fm-notify.sh "T" "M"`, the daemon hook, and the
# watcher hook all produce the same full toast. (--no-focus exists only so tests
# can exercise the opt-out path.)
#
# On WSL/Windows the toast is scenario="reminder" (ToastGeneric) so it persists,
# carries an explicit <audio> so it always sounds (a quiet-dropped toast plays
# nothing), and - by default - a "Go to firstmate" action wired to the registered
# Windows "firstmate:" URL protocol. Auto-focus was rejected as invasive: the
# toast NEVER steals the foreground on its own; only a CLICK fires the protocol
# -> a hidden VBS launcher -> bin/fm-focus.sh, which raises the host terminal and
# selects the firstmate tmux window+pane resolved dynamically at click time. Run
# `fm-notify.sh install` once to register that protocol and launcher (idempotent;
# WSL only, since the launcher shells through wsl.exe - a clean no-op elsewhere).
# firstmate's own pane id is recorded to state/.fm-tmux-pane (under the firstmate
# home) so the click lands on the exact pane; fm-focus.sh falls back to the claude
# pane whose cwd is the home if it moved.
#
# Backends - every platform mirrors the Windows behavior as closely as it
# robustly allows (persistent + sounding + click-to-focus where supported):
#   - WSL / native Windows -> raw WinRT toast via powershell.exe (no modules):
#       persistent + sound + click-to-focus, fully wired.
#   - macOS -> terminal-notifier when present (persistent alert + sound +
#       -execute click-to-focus -> bin/fm-focus.sh); else `osascript display
#       notification` WITH a sound (no persistence/click, the graceful fallback).
#   - Linux desktop -> notify-send --urgency=critical (persistent), a best-effort
#       sound via canberra-gtk-play/paplay, and notify-send --action click-to-
#       focus -> bin/fm-focus.sh where the desktop's daemon supports actions.
# The macOS and Linux paths are implemented and unit-tested for dispatch and
# argument-building, but NOT end-to-end verified (firstmate develops on WSL). What
# each delivers and needs installed is documented in AGENTS.md.
#
# Internal/testing knobs (not part of the public contract):
#   FM_NOTIFY_UNAME         override `uname -s` for platform detection tests.
#   FM_NOTIFY_PROC_VERSION  path read instead of /proc/version (WSL detection).
#   FM_TMUX_PANE_FILE       override the recorded-pane-id path (default derives
#                           from the firstmate home: <home>/state/.fm-tmux-pane).
#   FM_NOTIFY_BG            1 (default) backgrounds the dispatch; 0 runs it
#                           synchronously (deterministic for tests).
#   FM_NOTIFY_WIN_SOUND     Windows toast <audio> src (default the standard
#                           notification ding); operator-trusted, not user text.
#   FM_NOTIFY_MACOS_SOUND   macOS sound name for terminal-notifier/osascript
#                           (default Ping).
set -u

# Platform detection and the shared dynamic-pane resolution live in the sibling
# lib so the notifier and bin/fm-focus.sh share one definition. Sourcing by this
# script's own dir keeps it correct whether run or sourced.
# shellcheck source=bin/fm-focus-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-focus-lib.sh"

# ---------------------------------------------------------------------------
# Pure helpers (no side effects) - exercised directly by tests/fm-notify.test.sh.
# ---------------------------------------------------------------------------

# fm_notify_enabled: 0 when notifications are on (the default), 1 when the
# FM_NOTIFY toggle disables them. Unset means on.
fm_notify_enabled() {
  case "$(printf '%s' "${FM_NOTIFY:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no|disable|disabled) return 1 ;;
    *) return 0 ;;
  esac
}

# Platform detection (fm_detect_platform / _uname_s) is provided by the sourced
# bin/fm-focus-lib.sh - one definition shared with bin/fm-focus.sh.

# _fm_notify_self_dir: absolute dir of THIS script (bin/), resolved from its own
# BASH_SOURCE so it is correct whether run or sourced.
_fm_notify_self_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }

# _fm_notify_home: the firstmate home. From FM_HOME when set, else FM_ROOT_OVERRIDE,
# else this script's repo root (bin/ -> ..). The pane-id file and the click-to-focus
# launcher both derive from this; nothing is hardcoded.
_fm_notify_home() {
  local root
  root="${FM_ROOT_OVERRIDE:-$(cd "$(_fm_notify_self_dir)/.." 2>/dev/null && pwd)}"
  printf '%s' "${FM_HOME:-$root}"
}

# _fm_notify_pane_file: the stable path where firstmate records its own tmux pane
# id and fm-focus.sh reads it back. FM_TMUX_PANE_FILE overrides; the default lives
# under the firstmate home, never an absolute literal.
_fm_notify_pane_file() {
  printf '%s' "${FM_TMUX_PANE_FILE:-$(_fm_notify_home)/state/.fm-tmux-pane}"
}

# _b64_utf16: base64 of the UTF-16LE bytes of a string. The toast title/message
# are passed to PowerShell this way (decoded inside) so arbitrary text - including
# an escalation summary - can never break out of the script or need quoting.
# `base64 | tr -d '\n'` instead of GNU-only `base64 -w0`: BSD/macOS base64 has no
# -w flag, and stripping newlines yields the same single-line output everywhere.
_b64_utf16() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE 2>/dev/null | base64 2>/dev/null | tr -d '\n'; }

# _xml_escape: escape the five XML metacharacters so a value is safe inside an XML
# attribute. The "Open PR" action's URL is interpolated into the toast XML as an
# attribute (unlike the title/message, which are set via DOM text nodes), so it is
# escaped here to keep a stray quote or angle bracket from breaking the toast
# markup. Escape & first so the entity ampersands it introduces are not re-escaped.
_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# _build_windows_ps: assemble the PowerShell that shows a persistent, SOUNDING
# WinRT toast. The toast is scenario="reminder" (ToastGeneric) so it pops as a
# banner and stays until acted on, instead of dropping silently into the
# notification center, and carries an explicit <audio> so it always plays a sound
# (a toast that lands straight in the notification center otherwise makes no
# sound). With focus=1 (the default) it also carries a "Go to firstmate" action
# (and a body launch) wired to the "firstmate:" URL protocol, so a CLICK - never
# the toast itself - focuses the terminal+pane via bin/fm-focus.sh. Title/message
# are carried as base64 and set through DOM text nodes (never string-interpolated
# into the XML), so arbitrary escalation text can neither break the script nor
# inject toast markup. Uses the system PowerShell AppId (no third-party module); a
# custom "Firstmate" AppId is left out on purpose since an unregistered AppId can
# suppress the toast entirely.
_build_windows_ps() {
  local title=$1 msg=$2 focus=$3 open_url=$4 tb mb toast_open focus_action openpr_action sound audio url_esc
  tb=$(_b64_utf16 "$title")
  mb=$(_b64_utf16 "$msg")
  if [ "$focus" = 1 ]; then
    toast_open='<toast scenario="reminder" launch="firstmate:focus" activationType="protocol">'
    focus_action='    <action content="Go to firstmate" arguments="firstmate:focus" activationType="protocol"/>'
  else
    toast_open='<toast scenario="reminder">'
    focus_action=''
  fi
  # Optional second button: "Open PR" opens the PR/MR URL in the default browser.
  # activationType="protocol" with an https argument hands the URL to the OS, which
  # routes it to the default browser. The URL is XML-attribute-escaped (above).
  if [ -n "$open_url" ]; then
    url_esc=$(_xml_escape "$open_url")
    openpr_action="    <action content=\"Open PR\" activationType=\"protocol\" arguments=\"$url_esc\"/>"
  else
    openpr_action=''
  fi
  # Explicit, non-silent audio so the toast always sounds. The src is an
  # operator-trusted internal knob (never user/escalation text), defaulting to the
  # standard notification ding; loop="false" keeps the reminder scenario from
  # looping an alarm.
  sound="${FM_NOTIFY_WIN_SOUND:-ms-winsoundevent:Notification.Default}"
  audio="  <audio src=\"$sound\" loop=\"false\"/>"
  cat <<PS
\$ProgressPreference = 'SilentlyContinue'
\$ErrorActionPreference = 'Stop'
try {
  \$Title = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$tb'))
  \$Message = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$mb'))
  \$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  \$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
  \$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
  \$xml = @'
$toast_open
  <visual>
    <binding template="ToastGeneric">
      <text></text>
      <text></text>
    </binding>
  </visual>
$audio
  <actions>
$focus_action
$openpr_action
    <action content="Dismiss" arguments="dismiss" activationType="system"/>
  </actions>
</toast>
'@
  \$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
  \$doc.LoadXml(\$xml)
  \$nodes = \$doc.GetElementsByTagName('text')
  \$null = \$nodes.Item(0).AppendChild(\$doc.CreateTextNode(\$Title))
  \$null = \$nodes.Item(1).AppendChild(\$doc.CreateTextNode(\$Message))
  \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$doc)
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$AppId).Show(\$toast)
} catch { }
PS
}

# ---------------------------------------------------------------------------
# Dispatch (side-effecting). Each backend backgrounds its call unless
# FM_NOTIFY_BG=0, so a slow host call never blocks the caller.
# ---------------------------------------------------------------------------

# _run_bg: run a command non-blocking (fully detached subshell) by default, or
# synchronously when FM_NOTIFY_BG=0 (deterministic for tests).
_run_bg() {
  if [ "${FM_NOTIFY_BG:-1}" = 0 ]; then
    "$@" >/dev/null 2>&1
  else
    ( "$@" >/dev/null 2>&1 & )
  fi
}

fm_notify_windows() {
  local title=$1 msg=$2 focus=$3 open_url=$4 ps enc
  command -v powershell.exe >/dev/null 2>&1 || return 0
  command -v iconv >/dev/null 2>&1 || return 0
  command -v base64 >/dev/null 2>&1 || return 0
  ps=$(_build_windows_ps "$title" "$msg" "$focus" "$open_url")
  enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE 2>/dev/null | base64 2>/dev/null | tr -d '\n') || return 0
  [ -n "$enc" ] || return 0
  _run_bg powershell.exe -NoProfile -NonInteractive -EncodedCommand "$enc"
}

_osa_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# _sh_squote: POSIX single-quote a string so it survives as ONE argument when the
# result is re-parsed by a shell (terminal-notifier's -execute runs its string
# through a shell). Only firstmate-controlled paths are quoted this way - never
# untrusted title/message text, which is passed as separate notifier arguments.
_sh_squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# fm_notify_macos: mirror the Windows toast as closely as macOS robustly allows.
# terminal-notifier (when present) gives a persistent alert + sound + a single
# click action. With an --open URL the click action OPENS THE PR (-open <url>),
# the most useful action for a done-state notification; otherwise it click-to-
# focuses via -execute, which runs bin/fm-focus.sh (with FM_HOME) to raise the
# terminal and select the firstmate pane. terminal-notifier has one click action,
# so -open takes priority over -execute when a URL is present (best-effort macOS
# parity). Without terminal-notifier, fall back to `osascript display
# notification` WITH a sound - no persistence/click, but still better than a silent
# banner. Title/message are passed as discrete arguments (terminal-notifier) or
# escaped osascript string literals, never shell-interpolated.
fm_notify_macos() {
  local title=$1 msg=$2 focus=$3 focus_sh=$4 home=$5 open_url=$6 t m sound exe
  sound="${FM_NOTIFY_MACOS_SOUND:-Ping}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    if [ -n "$open_url" ]; then
      _run_bg terminal-notifier -title "$title" -message "$msg" -sound "$sound" -open "$open_url"
    elif [ "$focus" = 1 ] && [ -x "$focus_sh" ]; then
      # -execute is shell-evaluated: carry only firstmate's own quoted paths.
      exe="FM_HOME=$(_sh_squote "$home") $(_sh_squote "$focus_sh")"
      _run_bg terminal-notifier -title "$title" -message "$msg" -sound "$sound" -execute "$exe"
    else
      _run_bg terminal-notifier -title "$title" -message "$msg" -sound "$sound"
    fi
    return 0
  fi
  command -v osascript >/dev/null 2>&1 || return 0
  t=$(_osa_escape "$title"); m=$(_osa_escape "$msg")
  # Fallback: no persistence or click on plain osascript, but add a sound.
  _run_bg osascript -e "display notification \"$m\" with title \"$t\" sound name \"$sound\""
}

# _fm_notify_send_supports_action: 0 when this notify-send advertises --action in
# its help, i.e. the click-to-focus path is usable on this desktop's daemon.
_fm_notify_send_supports_action() {
  notify-send --help 2>&1 | grep -q -- '--action'
}

# _fm_linux_play_sound: best-effort, fully detached, never-fatal sound alongside
# notify-send. Tries an event sound (canberra-gtk-play), then a known freedesktop
# .oga via paplay/aplay - each guarded by tool AND file presence so it is a clean
# no-op when nothing is installed.
_fm_linux_play_sound() {
  if command -v canberra-gtk-play >/dev/null 2>&1; then
    ( canberra-gtk-play -i message >/dev/null 2>&1 & ) 2>/dev/null
    return 0
  fi
  local f
  for f in /usr/share/sounds/freedesktop/stereo/message.oga \
           /usr/share/sounds/freedesktop/stereo/bell.oga; do
    [ -r "$f" ] || continue
    if command -v paplay >/dev/null 2>&1; then ( paplay "$f" >/dev/null 2>&1 & ) 2>/dev/null; return 0; fi
    if command -v aplay  >/dev/null 2>&1; then ( aplay  "$f" >/dev/null 2>&1 & ) 2>/dev/null; return 0; fi
  done
  return 0
}

# _fm_linux_notify_action: post a critical (persistent) notification carrying up to
# two actions - a "Go to firstmate" click that runs bin/fm-focus.sh, and, with an
# --open URL, an "Open PR" click that runs xdg-open on the URL. notify-send --wait
# blocks until a click (or the daemon's timeout) and prints the chosen action key,
# so the caller always backgrounds this (it runs inside _run_bg). want_focus gates
# the focus action; a non-empty open_url adds the Open-PR action. Arrays are avoided
# for bash 3.2 safety, so the notify-send call is enumerated over the cases.
# Best-effort and never-fatal.
_fm_linux_notify_action() {
  local title=$1 msg=$2 focus_sh=$3 home=$4 open_url=$5 want_focus=$6 act
  if [ "$want_focus" = 1 ] && [ -n "$open_url" ]; then
    act=$(notify-send --urgency=critical --wait \
      --action='focus=Go to firstmate' --action='openpr=Open PR' -- "$title" "$msg" 2>/dev/null)
  elif [ "$want_focus" = 1 ]; then
    act=$(notify-send --urgency=critical --wait --action='focus=Go to firstmate' -- "$title" "$msg" 2>/dev/null)
  else
    act=$(notify-send --urgency=critical --wait --action='openpr=Open PR' -- "$title" "$msg" 2>/dev/null)
  fi
  case "$act" in
    focus)  FM_HOME="$home" "$focus_sh" >/dev/null 2>&1 ;;
    openpr) command -v xdg-open >/dev/null 2>&1 && xdg-open "$open_url" >/dev/null 2>&1 ;;
  esac
  return 0
}

# fm_notify_linux: mirror the Windows toast as closely as the Linux desktop
# robustly allows. --urgency=critical makes the notification persist; a best-
# effort sound plays alongside; and where the notification daemon supports
# actions, a "Go to firstmate" click runs bin/fm-focus.sh and (with an --open URL)
# an "Open PR" click runs xdg-open. Actions are desktop-environment-dependent, so
# it degrades to persistent+sound when the daemon has no action support. notify-send
# takes title/message as discrete arguments, never shell-interpolated.
fm_notify_linux() {
  local title=$1 msg=$2 focus=$3 focus_sh=$4 home=$5 open_url=$6 want_focus=0
  command -v notify-send >/dev/null 2>&1 || return 0
  _fm_linux_play_sound
  [ "$focus" = 1 ] && [ -x "$focus_sh" ] && want_focus=1
  if { [ "$want_focus" = 1 ] || [ -n "$open_url" ]; } && _fm_notify_send_supports_action; then
    _run_bg _fm_linux_notify_action "$title" "$msg" "$focus_sh" "$home" "$open_url" "$want_focus"
  else
    _run_bg notify-send --urgency=critical -- "$title" "$msg"
  fi
}

# ---------------------------------------------------------------------------
# Pluggable backend seam (firstmate issue #106).
# ---------------------------------------------------------------------------
# fm-notify is the FIRST backend (native OS toast + click-to-focus) of the
# pluggable notifier. Additional out-of-band backends plug in here - notably a phone push
# via ntfy or Pushover, since the captain carries an iPhone. To add one: write a
# fm_notify_push_<service> dispatcher gated by its own env/config and call it
# from fm_notify_dispatch alongside the native path. Left as a clean seam on
# purpose; no remote-push backend is built yet.

# fm_notify_dispatch: route to the right native backend for this platform. The
# single place a future push backend hooks in. The macOS/Linux backends receive
# the click-to-focus handler path and the firstmate home so their click action
# can run bin/fm-focus.sh with the right FM_HOME (Windows resolves both itself
# through the installed protocol launcher).
fm_notify_dispatch() {
  local title=$1 msg=$2 focus=$3 open_url=${4:-} focus_sh home
  focus_sh="$(_fm_notify_self_dir)/fm-focus.sh"
  home=$(_fm_notify_home)
  case "$(fm_detect_platform)" in
    wsl|windows) fm_notify_windows "$title" "$msg" "$focus" "$open_url" ;;
    macos)       fm_notify_macos "$title" "$msg" "$focus" "$focus_sh" "$home" "$open_url" ;;
    linux)       fm_notify_linux "$title" "$msg" "$focus" "$focus_sh" "$home" "$open_url" ;;
    *)           return 0 ;;  # unknown platform: quiet no-op
  esac
  # Future: fm_notify_push_ntfy "$title" "$msg"   (remote push, issue #106)
}

# ---------------------------------------------------------------------------
# Click-to-focus arming (the "firstmate:" protocol + hidden launcher + pane id).
# ---------------------------------------------------------------------------

# fm_notify_record_pane: record firstmate's OWN tmux pane id to the stable file
# fm-focus.sh reads, so a click lands on the exact pane. The path derives from the
# firstmate home (never hardcoded). A quiet no-op (still exits 0) when not inside
# tmux. Echoes the file path on success so the install step can report it.
fm_notify_record_pane() {
  local pane_file pane
  pane_file=$(_fm_notify_pane_file)
  command -v tmux >/dev/null 2>&1 || return 0
  pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || return 0
  [ -n "$pane" ] || return 0
  mkdir -p "$(dirname "$pane_file")" 2>/dev/null || true
  printf '%s\n' "$pane" > "$pane_file" 2>/dev/null || return 0
  printf '%s\n' "$pane_file"
}

# fm_notify_install: arm click-to-focus. Records firstmate's pane id (any platform
# with tmux), and on WSL registers the "firstmate:" URL protocol under HKCU and
# writes the hidden VBS launcher that runs bin/fm-focus.sh. Fully idempotent -
# safe to run repeatedly - and a clean no-op for the protocol bits off WSL (the
# launcher shells through wsl.exe, so native Windows/MINGW/Cygwin can't use it).
# Prints a short human summary. The launcher and protocol command carry no captain
# secrets; only local filesystem paths.
fm_notify_install() {
  local self_dir focus_sh pane_file platform home
  self_dir=$(_fm_notify_self_dir)
  focus_sh="$self_dir/fm-focus.sh"

  # Always: record firstmate's pane id so a click lands on the exact pane.
  if pane_file=$(fm_notify_record_pane) && [ -n "$pane_file" ]; then
    printf 'fm-notify: recorded firstmate pane id -> %s\n' "$pane_file"
  else
    printf 'fm-notify: no tmux pane to record (focus will fall back to cwd match)\n'
  fi

  # WSL only: the launcher shells through wsl.exe and the install needs wslpath,
  # so a native Windows (MINGW/Cygwin) shell can't arm this path. Skip cleanly there.
  platform=$(fm_detect_platform)
  case "$platform" in
    wsl) : ;;
    *) printf 'fm-notify: %s - click-to-focus protocol install skipped (WSL only)\n' "$platform"; return 0 ;;
  esac

  if [ ! -x "$focus_sh" ]; then
    printf 'fm-notify: focus handler not found/executable at %s\n' "$focus_sh" >&2
    return 1
  fi
  command -v reg.exe   >/dev/null 2>&1 || { printf 'fm-notify: reg.exe not found - cannot register the firstmate: protocol\n' >&2; return 1; }
  command -v wslpath   >/dev/null 2>&1 || { printf 'fm-notify: wslpath not found - cannot resolve a Windows launcher path\n' >&2; return 1; }
  command -v cmd.exe   >/dev/null 2>&1 || { printf 'fm-notify: cmd.exe not found - cannot resolve %%LOCALAPPDATA%%\n' >&2; return 1; }

  # Resolve a stable Windows-accessible launcher dir under %LOCALAPPDATA%.
  local appdata_win appdata_wsl vbs_dir vbs_wsl vbs_win wsl_cmd vbs_focus vbs_home
  appdata_win=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')
  [ -n "$appdata_win" ] || { printf 'fm-notify: could not resolve %%LOCALAPPDATA%%\n' >&2; return 1; }
  appdata_wsl=$(wslpath -u "$appdata_win" 2>/dev/null)
  [ -n "$appdata_wsl" ] || { printf 'fm-notify: could not translate %s to a WSL path\n' "$appdata_win" >&2; return 1; }
  vbs_dir="$appdata_wsl/firstmate"
  mkdir -p "$vbs_dir" || { printf 'fm-notify: could not create %s\n' "$vbs_dir" >&2; return 1; }
  vbs_wsl="$vbs_dir/fm-launch.vbs"

  # The hidden launcher: window style 0 so no console flashes. Pin the distro so a
  # multi-distro host still reaches the right bash, and run fm-focus.sh under the
  # SAME firstmate home that armed the pane file - so a custom home clicks into the
  # pane it recorded, matching the macOS/Linux backends which also pass the home
  # through. WScript.Shell.Run does NOT preserve an `env VAR=...` wrapper or quotes
  # around the distro, so neither survives the VBS -> wsl.exe chain: the distro is
  # passed UNQUOTED and the home is passed as bash's positional $1 (fm-focus.sh
  # reads $1 as FM_HOME). focus_sh and home are still VBS-escaped (embedded " -> "")
  # and wrapped in VBS double quotes, so a checkout path containing spaces still
  # reaches bash as one argument.
  home=$(_fm_notify_home)
  vbs_focus=${focus_sh//\"/\"\"}
  vbs_home=${home//\"/\"\"}
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    wsl_cmd="wsl.exe -d ${WSL_DISTRO_NAME} -e bash \"\"${vbs_focus}\"\" \"\"${vbs_home}\"\""
  else
    wsl_cmd="wsl.exe -e bash \"\"${vbs_focus}\"\" \"\"${vbs_home}\"\""
  fi
  printf 'CreateObject("WScript.Shell").Run "%s", 0, False\r\n' "$wsl_cmd" > "$vbs_wsl" \
    || { printf 'fm-notify: could not write the launcher %s\n' "$vbs_wsl" >&2; return 1; }

  vbs_win=$(wslpath -w "$vbs_wsl" 2>/dev/null)
  [ -n "$vbs_win" ] || { printf 'fm-notify: could not translate %s to a Windows path\n' "$vbs_wsl" >&2; return 1; }

  # Register the firstmate: URL protocol (idempotent; /f overwrites). The open
  # command runs the launcher hidden via wscript; %1 (the invoked URL) is passed
  # through and ignored by the launcher. Every write is checked, so ANY failure
  # fails the install instead of falsely reporting "armed".
  if ! { reg.exe add 'HKCU\Software\Classes\firstmate' /ve /d 'URL:firstmate Protocol' /f >/dev/null 2>&1 \
      && reg.exe add 'HKCU\Software\Classes\firstmate' /v 'URL Protocol' /d '' /f >/dev/null 2>&1 \
      && reg.exe add 'HKCU\Software\Classes\firstmate\shell\open\command' /ve \
           /d "wscript.exe //B //Nologo \"$vbs_win\" \"%1\"" /f >/dev/null 2>&1; }; then
    printf 'fm-notify: reg.exe failed to register the firstmate: protocol\n' >&2
    return 1
  fi

  printf 'fm-notify: registered firstmate: -> %s -> %s\n' "$vbs_win" "$focus_sh"
  printf 'fm-notify: click-to-focus armed\n'
  return 0
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
fm_notify_main() {
  local usage='usage: fm-notify.sh "<title>" "<message>" [--focus|--no-focus] [--open <url>]  |  fm-notify.sh install'
  # Subcommand: arm click-to-focus (protocol + launcher + pane id).
  case "${1:-}" in
    install|ensure|--install) fm_notify_install; return $? ;;
  esac

  # Focus is ON BY DEFAULT: every toast pops, sounds, persists, and is click-to-
  # focus. --no-focus opts out (tests only); --focus is accepted for explicitness.
  # --open <url> (or --open=<url>) adds the optional "Open PR" action button.
  local title="" msg="" focus=1 open_url="" nargs=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --focus) focus=1 ;;
      --no-focus) focus=0 ;;
      --open)
        # --open requires a following URL; reject a bare --open instead of
        # silently dropping the button and reporting success.
        [ $# -ge 2 ] || { echo "$usage" >&2; return 2; }
        shift
        open_url=$1
        ;;
      --open=*)
        open_url=${1#--open=}
        [ -n "$open_url" ] || { echo "$usage" >&2; return 2; }
        ;;
      --) shift; break ;;
      *)
        case $nargs in
          0) title=$1 ;;
          1) msg=$1 ;;
        esac
        nargs=$((nargs + 1))
        ;;
    esac
    shift
  done
  # Any positionals after `--`.
  while [ $# -gt 0 ]; do
    case $nargs in 0) title=$1 ;; 1) msg=$1 ;; esac
    nargs=$((nargs + 1)); shift
  done

  # The documented usage requires BOTH a title and a message; reject either
  # missing so a miswired notifier call fails fast instead of looking successful.
  if [ -z "$title" ] || [ -z "$msg" ]; then
    echo "$usage" >&2
    return 2
  fi

  # Toggle check AFTER arg parsing so a bad invocation still reports usage.
  fm_notify_enabled || return 0

  fm_notify_dispatch "$title" "$msg" "$focus" "$open_url"
  return 0
}

# Run only when executed, not when sourced (tests source the pure helpers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_notify_main "$@"
fi
