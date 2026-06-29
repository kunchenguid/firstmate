#!/usr/bin/env bash
# tests/fm-notify.test.sh - the platform-portable logic of bin/fm-notify.sh, the
# native out-of-band notifier (firstmate issue #106).
#
# The real toast (WinRT via powershell.exe) and the click-to-focus protocol only
# work on Windows, so they are guarded behind platform detection and NEVER run
# here: this suite pins the pure logic that runs on Linux CI - platform detection
# from a mocked uname/proc, the FM_NOTIFY=off short-circuit, argument handling,
# backend routing (with the host tools stubbed), the persistent scenario="reminder"
# toast and its click-to-focus action wiring, the pane-id recording and the
# "firstmate:" protocol install (with reg.exe/cmd.exe/wslpath/tmux stubbed), and
# the base64 carrying of title/message that keeps arbitrary text from injecting
# into the generated PowerShell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify.sh"
# Source the pure helpers (main runs only under the BASH_SOURCE guard when executed).
if [ -z "${FM_NOTIFY_TEST_SOURCED:-}" ]; then
  export FM_NOTIFY_TEST_SOURCED=1
  # shellcheck source=bin/fm-notify.sh
  . "$NOTIFY"
fi

TMP_ROOT=$(fm_test_tmproot fm-notify-tests)
mkdir -p "$TMP_ROOT"

# A fakebin whose powershell.exe / notify-send / osascript log every arg
# (NUL-delimited) so a test can inspect exactly what was dispatched.
make_notify_fakebin() {
  local dir=$1 log=$2 fakebin tool
  fakebin=$(fm_fakebin "$dir")
  for tool in powershell.exe notify-send osascript; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$log"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

# A fakebin with terminal-notifier + osascript that log every arg. Used by the
# macOS-mirror tests so terminal-notifier is "present".
make_macos_fakebin() {
  local dir=$1 log=$2 fakebin tool
  fakebin=$(fm_fakebin "$dir")
  for tool in terminal-notifier osascript; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$log"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

# A fakebin whose notify-send advertises (or not) --action in its --help, and
# logs every real call's args (NUL-delimited) to $NS_LOG. NS_SUPPORTS_ACTION=1
# in the environment makes --help mention --action so the click-to-focus path is
# taken; absent/0 makes it plain. So one stub serves both Linux variants.
make_linux_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/notify-send" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--help" ]; then
  echo "Usage: notify-send [OPTION...] <SUMMARY> [BODY]"
  [ "${NS_SUPPORTS_ACTION:-0}" = 1 ] && echo "  -A, --action=[NAME=]Text   Specifies an action"
  exit 0
fi
printf '%s\0' "$@" >> "$NS_LOG"
exit 0
SH
  chmod +x "$fakebin/notify-send"
  printf '%s\n' "$fakebin"
}

# Decode fm-notify's PowerShell -EncodedCommand back to UTF-8 text. The arg after
# -EncodedCommand in the NUL-delimited log is base64 of the UTF-16LE script.
decode_encoded_command() {
  local log=$1 enc
  enc=$(tr '\0' '\n' < "$log" | awk 'p{print;exit} /^-EncodedCommand$/{p=1}')
  printf '%s' "$enc" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null
}

# --- platform detection -----------------------------------------------------

test_platform_detection() {
  local pf
  pf="$TMP_ROOT/proc-wsl"; printf 'Linux version 6.6-microsoft-standard-WSL2\n' > "$pf"
  [ "$(FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" fm_detect_platform)" = wsl ] \
    || fail "WSL (microsoft in /proc/version) not detected as wsl"
  pf="$TMP_ROOT/proc-linux"; printf 'Linux version 6.6 generic\n' > "$pf"
  [ "$(FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" fm_detect_platform)" = linux ] \
    || fail "native Linux misdetected"
  [ "$(FM_NOTIFY_UNAME=Darwin fm_detect_platform)" = macos ] || fail "Darwin not macos"
  [ "$(FM_NOTIFY_UNAME=MINGW64_NT-10.0 fm_detect_platform)" = windows ] || fail "MINGW not windows"
  [ "$(FM_NOTIFY_UNAME=CYGWIN_NT-10.0 fm_detect_platform)" = windows ] || fail "CYGWIN not windows"
  [ "$(FM_NOTIFY_UNAME=Plan9 FM_NOTIFY_PROC_VERSION="$TMP_ROOT/none" fm_detect_platform)" = unknown ] \
    || fail "an unrecognized platform was not 'unknown'"
  pass "fm_detect_platform: wsl before linux, plus windows/macos/unknown"
}

# --- FM_NOTIFY toggle -------------------------------------------------------

test_enabled_toggle() {
  local v
  for v in '' on On weird; do
    FM_NOTIFY="$v" fm_notify_enabled || fail "FM_NOTIFY='$v' should be enabled"
  done
  for v in off OFF 0 false no disabled; do
    FM_NOTIFY="$v" fm_notify_enabled && fail "FM_NOTIFY='$v' should be disabled"
  done
  pass "fm_notify_enabled: on by default, disabled by off/0/false/no/disabled"
}

# --- argument handling ------------------------------------------------------

test_missing_title_usage() {
  local out rc
  out=$(bash "$NOTIFY" 2>&1); rc=$?
  expect_code 2 "$rc" "no args should exit 2"
  assert_contains "$out" "usage: fm-notify.sh" "missing-title did not print usage"
  pass "fm-notify: missing title prints usage and exits 2"
}

test_off_short_circuits_dispatch() {
  local dir log fakebin pf
  dir="$TMP_ROOT/off"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_notify_fakebin "$dir" "$log")
  pf="$dir/proc"; printf 'Linux generic\n' > "$pf"
  PATH="$fakebin:$PATH" FM_NOTIFY=off FM_NOTIFY_BG=0 \
    FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" \
    bash "$NOTIFY" "Firstmate" "should not fire" --focus || fail "off-mode exited non-zero"
  [ -s "$log" ] && fail "FM_NOTIFY=off still dispatched a backend"
  pass "FM_NOTIFY=off short-circuits all dispatch (exit 0, nothing sent)"
}

# --- backend routing (host tools stubbed) -----------------------------------

test_linux_persistent_plain_when_no_action_support() {
  # A notify-send WITHOUT --action support still gets the persistent (critical)
  # mirror with title + message; the click-to-focus path is skipped, never fatal.
  local dir fakebin log pf args
  dir="$TMP_ROOT/linux-plain"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_linux_fakebin "$dir")
  pf="$dir/proc"; printf 'Linux generic\n' > "$pf"
  NS_LOG="$log" NS_SUPPORTS_ACTION=0 \
    PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" \
    bash "$NOTIFY" "Firstmate" "ready for review" || fail "linux dispatch exited non-zero"
  args=$(tr '\0' '\n' < "$log")
  assert_contains "$args" "--urgency=critical" "notify-send missing the persistent (critical) urgency"
  assert_contains "$args" "Firstmate" "notify-send missing title"
  assert_contains "$args" "ready for review" "notify-send missing message"
  assert_not_contains "$args" "--action" "no-action daemon must not get a --action click path"
  pass "linux mirrors persistent (critical) notify-send and degrades without --action support"
}

test_linux_action_when_supported() {
  # When notify-send advertises --action, the default (focus-on) call wires the
  # "Go to firstmate" click-to-focus action on the persistent (critical) toast.
  local dir fakebin log pf args
  dir="$TMP_ROOT/linux-action"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_linux_fakebin "$dir")
  pf="$dir/proc"; printf 'Linux generic\n' > "$pf"
  NS_LOG="$log" NS_SUPPORTS_ACTION=1 \
    PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" \
    bash "$NOTIFY" "Firstmate" "a decision is needed" || fail "linux action dispatch exited non-zero"
  args=$(tr '\0' '\n' < "$log")
  assert_contains "$args" "--urgency=critical" "action path dropped the persistent urgency"
  assert_contains "$args" "--action=focus=Go to firstmate" "action path missing the focus action"
  assert_contains "$args" "--wait" "action path must --wait for the click"
  pass "linux adds the click-to-focus action when the notify-send daemon supports it"
}

test_macos_osascript_fallback_has_sound() {
  # With terminal-notifier ABSENT, fall back to osascript display notification -
  # now WITH a sound (still better than a silent banner).
  local dir log fakebin args
  dir="$TMP_ROOT/macos-fallback"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_notify_fakebin "$dir" "$log")  # no terminal-notifier here
  PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=Darwin \
    bash "$NOTIFY" "Firstmate" "a decision is needed" || fail "macos fallback exited non-zero"
  args=$(tr '\0' '\n' < "$log")
  assert_contains "$args" "display notification" "osascript missing the notification verb"
  assert_contains "$args" "a decision is needed" "osascript missing message"
  assert_contains "$args" "sound name" "osascript fallback must request a sound"
  pass "macos falls back to osascript display notification WITH a sound"
}

test_macos_terminal_notifier_persistent_sound_and_execute() {
  # With terminal-notifier PRESENT, the default (focus-on) call mirrors Windows:
  # a sound and an -execute click-to-focus that runs fm-focus.sh with FM_HOME.
  local dir log fakebin home args
  dir="$TMP_ROOT/macos-tn"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_macos_fakebin "$dir" "$log")
  home="$dir/home"; mkdir -p "$home"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=Darwin \
    bash "$NOTIFY" "Firstmate" "a decision is needed" || fail "macos terminal-notifier exited non-zero"
  args=$(tr '\0' '\n' < "$log")
  assert_contains "$args" "-sound" "terminal-notifier missing the sound flag"
  assert_contains "$args" "-execute" "terminal-notifier missing the click-to-focus -execute"
  assert_contains "$args" "fm-focus.sh" "-execute does not run the focus handler"
  assert_contains "$args" "FM_HOME=" "-execute does not pass the firstmate home"
  pass "macos uses terminal-notifier with sound + -execute click-to-focus when present"
}

test_macos_terminal_notifier_no_focus_omits_execute() {
  # --no-focus opts out of the click action even when terminal-notifier is present;
  # the sounding notification still fires.
  local dir log fakebin args
  dir="$TMP_ROOT/macos-tn-nofocus"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_macos_fakebin "$dir" "$log")
  PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=Darwin \
    bash "$NOTIFY" "Firstmate" "fyi" --no-focus || fail "macos --no-focus exited non-zero"
  args=$(tr '\0' '\n' < "$log")
  assert_contains "$args" "-sound" "terminal-notifier dropped the sound under --no-focus"
  assert_not_contains "$args" "-execute" "--no-focus must omit the -execute click action"
  pass "macos --no-focus keeps the sound but omits the click-to-focus -execute"
}

test_windows_bare_call_defaults_to_focus_sound_persist() {
  # The captain's bug: a toast fired WITHOUT the focus action dropped silently
  # into the notification center. A bare `fm-notify.sh "T" "M"` (no flags) must
  # now ALWAYS produce the full toast: persistent reminder, an explicit <audio> so
  # it sounds, and the click-to-focus action - never the silent-drop form.
  local dir log fakebin ps
  dir="$TMP_ROOT/win-bare"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_notify_fakebin "$dir" "$log")
  PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=MINGW64_NT-10.0 \
    bash "$NOTIFY" "Firstmate" "needs your decision" || fail "windows bare dispatch exited non-zero"
  ps=$(decode_encoded_command "$log")
  assert_contains "$ps" "ToastNotificationManager" "windows path did not build a toast"
  assert_contains "$ps" 'scenario="reminder"' "bare toast is not the persistent reminder scenario"
  assert_contains "$ps" "ToastGeneric" "toast is not ToastGeneric"
  assert_contains "$ps" '<audio ' "bare toast carries no explicit audio - it could drop silently"
  assert_contains "$ps" 'arguments="firstmate:focus"' "bare toast missing the default click-to-focus action"
  assert_contains "$ps" 'launch="firstmate:focus"' "bare toast missing the body launch"
  assert_contains "$ps" "Go to firstmate" "bare toast missing the focus action button"
  # Still click-to-focus only: never an auto-foreground.
  assert_not_contains "$ps" "AppActivate" "the toast must never auto-foreground (click-to-focus only)"
  pass "windows bare call defaults to persistent + sounding + click-to-focus (the silent-drop fix)"
}

test_windows_no_focus_flag_omits_click_action_but_keeps_sound() {
  # --no-focus (tests only) drops the focus action but the toast STILL persists
  # and sounds - never the silent-drop form.
  local dir log fakebin ps
  dir="$TMP_ROOT/win-noinfocus"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_notify_fakebin "$dir" "$log")
  PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=MINGW64_NT-10.0 \
    bash "$NOTIFY" "Firstmate" "no focus here" --no-focus || fail "windows --no-focus exited non-zero"
  ps=$(decode_encoded_command "$log")
  assert_contains "$ps" "ToastNotificationManager" "windows path did not build a toast"
  assert_contains "$ps" 'scenario="reminder"' "toast is not the persistent reminder scenario"
  assert_contains "$ps" "ToastGeneric" "toast is not ToastGeneric"
  assert_contains "$ps" '<audio ' "even --no-focus toast must still sound (explicit audio)"
  # --no-focus: no click-to-focus action and never an auto-focus AppActivate.
  assert_not_contains "$ps" "firstmate:focus" "--no-focus must not carry the focus action"
  assert_not_contains "$ps" "AppActivate" "the toast must never auto-foreground (click-to-focus only)"
  pass "windows --no-focus omits the focus action but keeps a persistent, sounding toast"
}

test_windows_focus_adds_click_to_focus_action_not_appactivate() {
  local dir log fakebin ps
  dir="$TMP_ROOT/win-focus"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_notify_fakebin "$dir" "$log")
  PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=MINGW64_NT-10.0 \
    bash "$NOTIFY" "Firstmate" "decision needed" --focus || fail "windows+focus exited non-zero"
  ps=$(decode_encoded_command "$log")
  # --focus wires the click-to-focus protocol action + body launch + sound...
  assert_contains "$ps" 'scenario="reminder"' "focus toast is not the persistent reminder scenario"
  assert_contains "$ps" '<audio ' "focus toast carries no explicit audio"
  assert_contains "$ps" 'arguments="firstmate:focus"' "--focus did not add the firstmate: protocol action"
  assert_contains "$ps" 'launch="firstmate:focus"' "--focus did not wire the toast body launch"
  assert_contains "$ps" "Go to firstmate" "--focus did not add the focus action button"
  # ...but NEVER auto-focuses. Auto-focus was rejected as invasive.
  assert_not_contains "$ps" "AppActivate" "--focus must not auto-foreground; focus happens only on click"
  pass "windows --focus adds the click-to-focus protocol action, never an auto AppActivate"
}

test_title_message_carried_as_base64_not_injected() {
  # A title/message with PowerShell-dangerous characters must be carried as
  # base64 data, never interpolated as code. The decoded script must contain the
  # base64 of the text but NOT the raw dangerous substring.
  local dir log fakebin ps title msg tb mb
  dir="$TMP_ROOT/inject"; mkdir -p "$dir"
  log="$dir/calls.log"; : > "$log"
  fakebin=$(make_notify_fakebin "$dir" "$log")
  title="Firstmate"
  msg="'@; Remove-Item C:\\ -Recurse \$(whoami)"
  PATH="$fakebin:$PATH" FM_NOTIFY=on FM_NOTIFY_BG=0 FM_NOTIFY_UNAME=MINGW64_NT-10.0 \
    bash "$NOTIFY" "$title" "$msg" || fail "windows inject-case exited non-zero"
  ps=$(decode_encoded_command "$log")
  tb=$(printf '%s' "$title" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  mb=$(printf '%s' "$msg" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  assert_contains "$ps" "FromBase64String('$tb')" "title not carried as base64"
  assert_contains "$ps" "FromBase64String('$mb')" "message not carried as base64"
  assert_not_contains "$ps" "Remove-Item C:\\ -Recurse" "raw dangerous text leaked into the script"
  pass "title/message are base64-carried, not injectable into the PowerShell"
}

# --- click-to-focus arming: pane-id recording + protocol install ------------

test_record_pane_writes_pane_file() {
  # firstmate records its OWN pane id to the FM_HOME-derived path fm-focus.sh
  # reads. The path is never hardcoded: it follows FM_HOME.
  local dir fakebin home out pane_file
  dir="$TMP_ROOT/record-pane"; mkdir -p "$dir"
  home="$dir/home"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%%7\n'
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" fm_notify_record_pane)
  pane_file="$home/state/.fm-tmux-pane"
  [ "$out" = "$pane_file" ] || fail "record_pane did not echo the FM_HOME-derived path: '$out'"
  assert_grep '%7' "$pane_file" "recorded pane id not written to the derived file"
  pass "fm_notify_record_pane writes the pane id under the FM_HOME-derived path"
}

test_install_skips_protocol_off_wsl() {
  # Off WSL: the pane id is still recorded, but the protocol install is a clean
  # no-op (no reg.exe), never an error - the launcher shells through wsl.exe.
  local dir fakebin home pf out
  dir="$TMP_ROOT/install-linux"; mkdir -p "$dir"
  home="$dir/home"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%%3\n'
exit 0
SH
  chmod +x "$fakebin/tmux"
  pf="$dir/proc"; printf 'Linux generic\n' > "$pf"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" \
        fm_notify_install) || fail "install exited non-zero off WSL"
  assert_contains "$out" "recorded firstmate pane id" "install did not record the pane id"
  assert_contains "$out" "skipped (WSL only)" "install did not skip the protocol off WSL"
  assert_grep '%3' "$home/state/.fm-tmux-pane" "pane file not written by install"
  pass "fm_notify_install records the pane and skips the protocol off WSL"
}

test_install_skips_protocol_on_native_windows() {
  # Native Windows (MINGW/Cygwin) is NOT WSL: the launcher needs wsl.exe, so the
  # protocol install must skip cleanly there too instead of writing a broken one.
  local dir fakebin home out
  dir="$TMP_ROOT/install-winnative"; mkdir -p "$dir"
  home="$dir/home"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%%4\n'
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_NOTIFY_UNAME=MINGW64_NT-10.0 \
        fm_notify_install) || fail "install exited non-zero on native Windows"
  assert_contains "$out" "windows - click-to-focus protocol install skipped (WSL only)" \
    "native Windows did not skip the WSL-only protocol install"
  assert_grep '%4' "$home/state/.fm-tmux-pane" "pane file not written by install on native Windows"
  pass "fm_notify_install skips the WSL-only protocol install on native Windows"
}

test_install_registers_protocol_on_wsl() {
  # On WSL (microsoft in /proc/version): register the firstmate: protocol under
  # HKCU and write the hidden VBS launcher pointing at the installed fm-focus.sh.
  # reg.exe / cmd.exe / wslpath / tmux are stubbed so nothing touches a real host.
  local dir fakebin home pf reglog out reg vbs focus_sh
  dir="$TMP_ROOT/install-wsl"; mkdir -p "$dir/appdata"
  home="$dir/home"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  reglog="$dir/reg.log"; : > "$reglog"
  pf="$dir/proc"; printf 'Linux version 6.6-microsoft-standard-WSL2\n' > "$pf"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%%9\n'
exit 0
SH
  cat > "$fakebin/cmd.exe" <<'SH'
#!/usr/bin/env bash
printf 'C:\\Users\\test\\AppData\\Local\r\n'
exit 0
SH
  # -u <winpath> -> our scratch appdata dir; -w <wslpath> -> a fixed Windows path.
  cat > "$fakebin/wslpath" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then printf '%s\n' "$FAKE_APPDATA"; else printf '%s\n' 'C:\fake\fm-launch.vbs'; fi
SH
  cat > "$fakebin/reg.exe" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$reglog"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/cmd.exe" "$fakebin/wslpath" "$fakebin/reg.exe"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" WSL_DISTRO_NAME=TestDistro FAKE_APPDATA="$dir/appdata" \
        FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" fm_notify_install) \
    || fail "install exited non-zero on WSL"
  assert_contains "$out" "click-to-focus armed" "install did not report arming"
  reg=$(tr '\0' '\n' < "$reglog")
  assert_contains "$reg" 'HKCU\Software\Classes\firstmate\shell\open\command' "protocol command key not registered"
  assert_contains "$reg" 'wscript.exe //B //Nologo "C:\fake\fm-launch.vbs" "%1"' "open command not wired to the launcher"
  vbs=$(cat "$dir/appdata/firstmate/fm-launch.vbs")
  assert_contains "$vbs" 'WScript.Shell' "launcher is not a WScript.Shell .Run"
  assert_contains "$vbs" 'wsl.exe -d TestDistro -e bash' "launcher does not pin the distro and run bash"
  assert_contains "$vbs" ', 0, False' "launcher does not run hidden (window style 0)"
  focus_sh="$ROOT/bin/fm-focus.sh"
  # The fm-focus.sh path is wrapped in VBS-escaped quotes ("") so a checkout path
  # with spaces still reaches bash as one argument.
  assert_contains "$vbs" "-e bash \"\"$focus_sh\"\"" "launcher does not quote the fm-focus.sh path for spaces"
  pass "fm_notify_install registers the firstmate: protocol + hidden launcher (quoted path) on WSL"
}

test_install_fails_when_any_registry_write_fails() {
  # Every reg.exe write is checked, not just the last: if an EARLIER write fails,
  # install must fail (non-zero, no "armed") instead of falsely reporting success.
  local dir fakebin home pf out rc
  dir="$TMP_ROOT/install-regfail"; mkdir -p "$dir/appdata"
  home="$dir/home"; mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  pf="$dir/proc"; printf 'Linux version 6.6-microsoft-standard-WSL2\n' > "$pf"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%%9\n'
exit 0
SH
  cat > "$fakebin/cmd.exe" <<'SH'
#!/usr/bin/env bash
printf 'C:\\Users\\test\\AppData\\Local\r\n'
exit 0
SH
  cat > "$fakebin/wslpath" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then printf '%s\n' "$FAKE_APPDATA"; else printf '%s\n' 'C:\fake\fm-launch.vbs'; fi
SH
  # reg.exe fails ONLY on the first write (the URL:firstmate Protocol default value).
  cat > "$fakebin/reg.exe" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "URL:firstmate Protocol" ] && exit 1; done
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/cmd.exe" "$fakebin/wslpath" "$fakebin/reg.exe"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" WSL_DISTRO_NAME=TestDistro FAKE_APPDATA="$dir/appdata" \
        FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" fm_notify_install 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "install returned 0 despite an early registry write failing"
  assert_not_contains "$out" "click-to-focus armed" "install falsely reported armed after a registry write failed"
  assert_contains "$out" "reg.exe failed" "install did not report the registry failure"
  pass "fm_notify_install fails when ANY registry write fails, not just the last"
}

test_platform_detection
test_enabled_toggle
test_missing_title_usage
test_off_short_circuits_dispatch
test_linux_persistent_plain_when_no_action_support
test_linux_action_when_supported
test_macos_osascript_fallback_has_sound
test_macos_terminal_notifier_persistent_sound_and_execute
test_macos_terminal_notifier_no_focus_omits_execute
test_windows_bare_call_defaults_to_focus_sound_persist
test_windows_no_focus_flag_omits_click_action_but_keeps_sound
test_windows_focus_adds_click_to_focus_action_not_appactivate
test_title_message_carried_as_base64_not_injected
test_record_pane_writes_pane_file
test_install_skips_protocol_off_wsl
test_install_skips_protocol_on_native_windows
test_install_registers_protocol_on_wsl
test_install_fails_when_any_registry_write_fails
