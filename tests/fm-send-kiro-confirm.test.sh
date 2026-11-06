#!/usr/bin/env bash
# fm-send typed-plane submit confirmation for an explicit tmux kiro target
# that has no task meta in this home.
#
# A recorded kiro task names harness=kiro, which scopes the kiro-only
# composer rules (near-gray idle placeholder and hinted idle row) so a
# finished kiro composer reads empty. An explicit session:window send has
# no meta, so TARGET_HARNESS used to stay empty: the same idle placeholder
# read pending, extra Enters were pressed, and fm-send exited 3 even though
# kiro had accepted the message. fm-send now detects kiro from the live
# pane's foreground process group when meta is absent; any other process
# leaves the unknown-harness path unchanged.
#
# These cases are hermetic (stubbed tmux + ps + sleep, no real agent):
#   1. No meta, foreground comm is kiro-cli, kiro idle placeholder: exit 0.
#   2. No meta, foreground comm is bash, same placeholder: exit 3 pending.
#   3. No meta, foreground comm is bash, bordered empty composer: exit 0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-kiro-confirm)

# kiro_idle_screen: the styled idle row that reads empty only under the
# kiro composer scope, pending under the shared rules. Same truecolor grey
# the portable kiro composer cases pin.
kiro_idle_screen() {
  local esc
  esc=$(printf '\033')
  printf 'transcript line\n› %s[38;2;158;158;158mask a question or describe a task ↵%s[0m\n' "$esc" "$esc"
}

# make_stubs <dir> <fg-comm> <screen-kind>
# screen-kind is kiro-idle or empty-border. fg-comm is the pane foreground
# process name the ancestry walk sees (kiro-cli or bash).
make_stubs() {
  local dir=$1 fg_comm=$2 screen_kind=$3 fb="$1/fakebin"
  mkdir -p "$fb"
  case "$screen_kind" in
    kiro-idle) kiro_idle_screen >"$dir/screen" ;;
    empty-border) printf '╭────╮\n│    │\n╰────╯\n' >"$dir/screen" ;;
    *) fail "unknown screen kind '$screen_kind'" ;;
  esac
  cat >"$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$dir/tmux.log"
case "\${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_tty*) printf '/dev/pts/9\n'; exit 0 ;;
        *pane_pid*) printf '4242\n'; exit 0 ;;
        *pane_current_command*) printf '$fg_comm\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0 ;;
  capture-pane)
    cat "$dir/screen"
    exit 0 ;;
  list-windows) printf 'win\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/ps" <<SH
#!/usr/bin/env bash
set -u
args=" \$* "
case "\$args" in
  *" -t pts/9 "*)
    printf ' 4242  4242  4242 $fg_comm\n'
    exit 0 ;;
esac
pid=
prev=
for a in "\$@"; do
  if [ "\$prev" = -p ]; then pid=\$a; break; fi
  case "\$a" in
    -p*) pid=\${a#-p} ;;
  esac
  prev=\$a
done
[ -n "\$pid" ] || exit 1
[ "\$pid" = 4242 ] || exit 1
case "\$args" in
  *"comm="*) printf '$fg_comm\n'; exit 0 ;;
  *"args="*) printf '$fg_comm\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/ps"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fg-comm> <screen-kind>: send a typed message to sess:win with
# no task meta. Prints the case dir; rc is in $dir/rc, stderr in $dir/err.
run_send() {
  local fg_comm=$1 screen_kind=$2 dir fb rc
  dir="$TMP_ROOT/case-$RANDOM-$RANDOM"
  mkdir -p "$dir/state"
  : >"$dir/tmux.log"
  fb=$(make_stubs "$dir" "$fg_comm" "$screen_kind")
  rc=0
  (
    export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
    export PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir"
    "$SEND" sess:win 'steer the kiro pane' >"$dir/out" 2>"$dir/err"
  ) || rc=$?
  printf '%s\n' "$rc" >"$dir/rc"
  printf '%s\n' "$dir"
}

enter_count() { # <dir>
  grep -c ' Enter$' "$1/tmux.log" 2>/dev/null || printf '0\n'
}

# Explicit kiro pane, no meta: the idle placeholder must confirm, not exit 3.
case_dir=$(run_send kiro-cli kiro-idle)
expect_code 0 "$(cat "$case_dir/rc")" \
  "explicit kiro target with no meta should confirm the idle placeholder"
grep -q 'unconfirmed' "$case_dir/err" && \
  fail "explicit kiro send: unconfirmed text present despite confirmed submit"$'\n'"$(cat "$case_dir/err")"
[ "$(enter_count "$case_dir")" = 1 ] || \
  fail "explicit kiro send: expected one Enter after a confirmed idle composer, got $(enter_count "$case_dir")"$'\n'"$(cat "$case_dir/tmux.log")"
pass "fm-send: a meta-less explicit kiro target confirms its idle placeholder"

# Same placeholder without a kiro process: shared rules still read pending.
case_dir=$(run_send bash kiro-idle)
expect_code 3 "$(cat "$case_dir/rc")" \
  "explicit non-kiro target with the kiro idle placeholder should stay unconfirmed"
grep -q 'verdict=pending' "$case_dir/err" || \
  fail "explicit non-kiro send: expected verdict=pending"$'\n'"$(cat "$case_dir/err")"
[ "$(enter_count "$case_dir")" = 3 ] || \
  fail "explicit non-kiro send: expected three Enter retries on pending, got $(enter_count "$case_dir")"$'\n'"$(cat "$case_dir/tmux.log")"
pass "fm-send: a meta-less non-kiro explicit target keeps the shared pending verdict"

# Default empty composer on a non-kiro explicit target: unchanged fast confirm.
case_dir=$(run_send bash empty-border)
expect_code 0 "$(cat "$case_dir/rc")" \
  "explicit non-kiro target with an empty composer should still confirm"
grep -q 'unconfirmed' "$case_dir/err" && \
  fail "explicit empty-composer send: unconfirmed text present"$'\n'"$(cat "$case_dir/err")"
pass "fm-send: a meta-less non-kiro explicit target still confirms an empty composer"
