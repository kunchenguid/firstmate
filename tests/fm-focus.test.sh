#!/usr/bin/env bash
# tests/fm-focus.test.sh - bin/fm-focus.sh, the click-to-focus handler that the
# Windows "firstmate:" protocol runs when the captain clicks the notification.
#
# The real AppActivate (powershell.exe) only works on Windows, so it is stubbed to
# a no-op here and NEVER raises a window. What this suite pins is the part that
# must be correct on every host: the tmux window+pane is resolved DYNAMICALLY at
# click time with NOTHING hardcoded - no session name, window index, or pane
# literal. The proof is that focus lands correctly even when the session is NOT
# named "firstmate" (session-independence), via the recorded pane id and via the
# cwd-of-the-home fallback when that pane is gone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FOCUS="$ROOT/bin/fm-focus.sh"

TMP_ROOT=$(fm_test_tmproot fm-focus-tests)
mkdir -p "$TMP_ROOT"

# make_tmux_fakebin <dir> <log>: a fakebin whose `tmux` answers from env-provided
# fixtures and logs every call (NUL-delimited), plus a no-op powershell.exe so the
# host-raise step never touches a real Windows window.
#   TMUX_STUB_PANES    newline list of existing pane ids (for `list-panes -F '#{pane_id}'`)
#   TMUX_STUB_FALLBACK newline list of "<id> <cmd> <path>" (for the 3-field list-panes)
#   TMUX_STUB_WIN      what display-message resolves '#{session_name}:#{window_index}' to
make_tmux_fakebin() {
  local dir=$1 log=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$log"
cmd=\$1; shift
case "\$cmd" in
  list-panes)
    fmt=""
    while [ \$# -gt 0 ]; do [ "\$1" = "-F" ] && { fmt=\$2; break; }; shift; done
    if [ "\$fmt" = '#{pane_id}' ]; then printf '%s\n' "\$TMUX_STUB_PANES"
    else printf '%s\n' "\$TMUX_STUB_FALLBACK"; fi ;;
  display-message) printf '%s\n' "\$TMUX_STUB_WIN" ;;
  select-window|select-pane) : ;;
esac
exit 0
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/powershell.exe"
  printf '%s\n' "$fakebin"
}

# --- recorded pane id, session NOT named firstmate --------------------------

test_recorded_pane_resolves_nonfirstmate_session() {
  local dir log fakebin pane_file calls
  dir="$TMP_ROOT/recorded"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  pane_file="$dir/pane"; printf '%%5\n' > "$pane_file"
  # The recorded pane %5 exists and lives in a session named "work" (not firstmate).
  PATH="$fakebin:$PATH" FM_TMUX_PANE_FILE="$pane_file" \
    TMUX_STUB_PANES='%5' TMUX_STUB_WIN='work:3' TMUX_STUB_FALLBACK='' \
    bash "$FOCUS" || fail "fm-focus exited non-zero"
  calls=$(tr '\0' '\n' < "$log")
  # It must select the CURRENT session:window resolved for the pane, never a
  # hardcoded "firstmate" target...
  assert_contains "$calls" "select-window" "fm-focus did not select a window"
  assert_contains "$calls" "work:3" "fm-focus did not target the pane's CURRENT session:window"
  assert_not_contains "$calls" "firstmate:" "fm-focus used a hardcoded firstmate target"
  # ...and select the recorded pane itself.
  assert_contains "$calls" "select-pane" "fm-focus did not select the pane"
  assert_contains "$calls" "%5" "fm-focus did not select the recorded pane id"
  pass "fm-focus resolves a recorded pane in a non-firstmate session, nothing hardcoded"
}

# --- fallback: recorded pane gone, locate claude pane by cwd of the home ------

test_fallback_finds_claude_pane_by_home_cwd() {
  local dir log fakebin pane_file home calls fb
  dir="$TMP_ROOT/fallback"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  home="$dir/home"; mkdir -p "$home"
  # The recorded pane %99 no longer exists; only %5 (claude, cwd == home) and an
  # unrelated %6 are live, again in a session not named firstmate. The 3-field
  # list-panes output is TAB-delimited (matching fm-focus's awk -F '\t').
  pane_file="$dir/pane"; printf '%%99\n' > "$pane_file"
  fb=$(printf '%%6\tbash\t/somewhere/else\n%%5\tclaude\t%s' "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_TMUX_PANE_FILE="$pane_file" \
    TMUX_STUB_PANES='%5
%6' TMUX_STUB_WIN='ops:1' TMUX_STUB_FALLBACK="$fb" \
    bash "$FOCUS" || fail "fm-focus exited non-zero in the fallback path"
  calls=$(tr '\0' '\n' < "$log")
  assert_contains "$calls" "%5" "fallback did not pick the claude pane whose cwd is the home"
  assert_contains "$calls" "ops:1" "fallback did not resolve the pane's CURRENT session:window"
  assert_not_contains "$calls" "%99" "fallback wrongly selected the stale recorded pane"
  pass "fm-focus falls back to the claude pane whose cwd is the firstmate home"
}

test_fallback_handles_home_with_spaces() {
  # A firstmate home under a path with spaces must still match exactly: the
  # tab-delimited list-panes parse means $3 is the WHOLE path, not its first word.
  local dir log fakebin pane_file home calls fb
  dir="$TMP_ROOT/fallback-spaces"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  home="$dir/My Projects/firstmate"; mkdir -p "$home"
  pane_file="$dir/pane"; printf '%%99\n' > "$pane_file"
  fb=$(printf '%%7\tclaude\t%s' "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_TMUX_PANE_FILE="$pane_file" \
    TMUX_STUB_PANES='%7' TMUX_STUB_WIN='work:2' TMUX_STUB_FALLBACK="$fb" \
    bash "$FOCUS" || fail "fm-focus exited non-zero with a spaced home"
  calls=$(tr '\0' '\n' < "$log")
  assert_contains "$calls" "%7" "spaced-home fallback did not match the claude pane by full path"
  assert_contains "$calls" "work:2" "spaced-home fallback did not resolve the current session:window"
  pass "fm-focus fallback matches a firstmate home whose path contains spaces"
}

# --- platform dispatch: macOS and Linux raise the host terminal, then select ---
# The terminal-raise tools (osascript activate, wmctrl/xdotool) are stubbed so
# nothing touches a real desktop; what is pinned is that each platform path raises
# the terminal AND then runs the SAME shared dynamic pane select.

test_macos_raises_terminal_then_selects_pane() {
  local dir log osa_log fakebin pane_file osa calls
  dir="$TMP_ROOT/macos"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  osa_log="$dir/osa.log"; : > "$osa_log"
  cat > "$fakebin/osascript" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$osa_log"
exit 0
SH
  chmod +x "$fakebin/osascript"
  pane_file="$dir/pane"; printf '%%5\n' > "$pane_file"
  PATH="$fakebin:$PATH" FM_NOTIFY_UNAME=Darwin FM_TMUX_PANE_FILE="$pane_file" \
    TMUX_STUB_PANES='%5' TMUX_STUB_WIN='work:3' TMUX_STUB_FALLBACK='' \
    bash "$FOCUS" || fail "fm-focus (macos) exited non-zero"
  osa=$(tr '\0' '\n' < "$osa_log")
  assert_contains "$osa" "activate" "macos focus did not activate a terminal app"
  calls=$(tr '\0' '\n' < "$log")
  assert_contains "$calls" "select-pane" "macos focus did not select the pane"
  assert_contains "$calls" "%5" "macos focus did not select the recorded pane id"
  assert_contains "$calls" "work:3" "macos focus did not resolve the pane's CURRENT session:window"
  pass "fm-focus on macOS activates the terminal then selects the firstmate pane"
}

test_macos_explicit_term_override_is_activated() {
  # FM_FOCUS_MACOS_TERM names the terminal app to activate directly (no detection).
  local dir log osa_log fakebin pane_file osa
  dir="$TMP_ROOT/macos-override"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  osa_log="$dir/osa.log"; : > "$osa_log"
  cat > "$fakebin/osascript" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$osa_log"
exit 0
SH
  chmod +x "$fakebin/osascript"
  pane_file="$dir/pane"; printf '%%5\n' > "$pane_file"
  PATH="$fakebin:$PATH" FM_NOTIFY_UNAME=Darwin FM_FOCUS_MACOS_TERM='iTerm' \
    FM_TMUX_PANE_FILE="$pane_file" TMUX_STUB_PANES='%5' TMUX_STUB_WIN='work:3' TMUX_STUB_FALLBACK='' \
    bash "$FOCUS" || fail "fm-focus (macos override) exited non-zero"
  osa=$(tr '\0' '\n' < "$osa_log")
  assert_contains "$osa" 'tell application "iTerm" to activate' "macos override did not activate the named app"
  pass "fm-focus on macOS activates the FM_FOCUS_MACOS_TERM app when set"
}

test_linux_raises_window_then_selects_pane() {
  local dir log wm_log fakebin pane_file pf wm calls
  dir="$TMP_ROOT/linux"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  wm_log="$dir/wmctrl.log"; : > "$wm_log"
  cat > "$fakebin/wmctrl" <<SH
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$wm_log"
exit 0
SH
  chmod +x "$fakebin/wmctrl"
  pane_file="$dir/pane"; printf '%%8\n' > "$pane_file"
  pf="$dir/proc"; printf 'Linux generic\n' > "$pf"
  PATH="$fakebin:$PATH" FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" \
    FM_FOCUS_LINUX_WINDOW='firstmate-term' FM_TMUX_PANE_FILE="$pane_file" \
    TMUX_STUB_PANES='%8' TMUX_STUB_WIN='ops:2' TMUX_STUB_FALLBACK='' \
    bash "$FOCUS" || fail "fm-focus (linux) exited non-zero"
  wm=$(tr '\0' '\n' < "$wm_log")
  assert_contains "$wm" "firstmate-term" "linux focus did not raise the configured window via wmctrl"
  calls=$(tr '\0' '\n' < "$log")
  assert_contains "$calls" "%8" "linux focus did not select the recorded pane id"
  assert_contains "$calls" "ops:2" "linux focus did not resolve the pane's CURRENT session:window"
  pass "fm-focus on Linux raises the window (wmctrl) then selects the firstmate pane"
}

test_linux_degrades_to_select_when_no_window_found() {
  # When the GUI raise finds no window (here: xdotool present but matching
  # nothing, and no FM_FOCUS_LINUX_WINDOW), the raise is a clean no-op but the
  # pane select STILL runs - the universally valuable half always happens.
  local dir log fakebin pane_file pf calls
  dir="$TMP_ROOT/linux-noraise"; mkdir -p "$dir"
  log="$dir/tmux.log"; : > "$log"
  fakebin=$(make_tmux_fakebin "$dir" "$log")
  # xdotool that matches no window (prints nothing); wmctrl is not provided, and
  # no FM_FOCUS_LINUX_WINDOW is set, so the raise degrades to a no-op.
  cat > "$fakebin/xdotool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/xdotool"
  pane_file="$dir/pane"; printf '%%8\n' > "$pane_file"
  pf="$dir/proc"; printf 'Linux generic\n' > "$pf"
  PATH="$fakebin:$PATH" FM_NOTIFY_UNAME=Linux FM_NOTIFY_PROC_VERSION="$pf" \
    FM_TMUX_PANE_FILE="$pane_file" TMUX_STUB_PANES='%8' TMUX_STUB_WIN='ops:2' TMUX_STUB_FALLBACK='' \
    bash "$FOCUS" || fail "fm-focus (linux no-raise) exited non-zero"
  calls=$(tr '\0' '\n' < "$log")
  assert_contains "$calls" "%8" "linux focus did not select the pane when no window was found"
  assert_contains "$calls" "select-window" "linux focus skipped the window select when the raise was a no-op"
  pass "fm-focus on Linux still selects the pane when the window raise finds nothing"
}

test_recorded_pane_resolves_nonfirstmate_session
test_fallback_finds_claude_pane_by_home_cwd
test_fallback_handles_home_with_spaces
test_macos_raises_terminal_then_selects_pane
test_macos_explicit_term_override_is_activated
test_linux_raises_window_then_selects_pane
test_linux_degrades_to_select_when_no_window_found
