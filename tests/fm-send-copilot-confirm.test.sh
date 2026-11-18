#!/usr/bin/env bash
# fm-send typed-plane submit confirmation for an explicit tmux Copilot target
# that has no task meta in this home.
#
# Copilot's composer reader (the `❯` row between two rules) applies only when the
# recorded harness is copilot. An explicit session:window send has no meta, so
# fm-send detects copilot from the live pane's foreground process (kernel name
# MainThread, argv[0] copilot, named by fm-harness.sh ancestry); any other process
# leaves the unknown-harness path unchanged.
#
# These cases are hermetic (stubbed tmux + ps + sleep, no real agent):
#   1. No meta, foreground argv[0] is copilot, idle rule-box composer: exit 0.
#   2. No meta, foreground is bash, the same screen: the shared reader stays unconfirmed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-copilot-confirm)
IDLE_SCREEN="$ROOT/tests/captures/copilot-1.0.105-tmux/idle.pane"

# make_stubs <dir> <fg-comm> <fg-args>
make_stubs() {
  local dir=$1 fg_comm=$2 fg_args=$3 fb="$1/fakebin"
  mkdir -p "$fb"
  cp "$IDLE_SCREEN" "$dir/screen"
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
  *"args="*) printf '$fg_args\n'; exit 0 ;;
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

# run_send <fg-comm> <fg-args>: send a typed message to sess:win with no task meta.
# Prints the case dir; rc is in $dir/rc, stderr in $dir/err.
run_send() {
  local fg_comm=$1 fg_args=$2 dir fb rc
  dir="$TMP_ROOT/case-$RANDOM-$RANDOM"
  mkdir -p "$dir/state"
  : >"$dir/tmux.log"
  fb=$(make_stubs "$dir" "$fg_comm" "$fg_args")
  rc=0
  (
    export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
    export PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir"
    "$SEND" sess:win 'steer the copilot pane' >"$dir/out" 2>"$dir/err"
  ) || rc=$?
  printf '%s\n' "$rc" >"$dir/rc"
  printf '%s\n' "$dir"
}

enter_count() { # <dir>
  grep -c ' Enter$' "$1/tmux.log" 2>/dev/null || printf '0\n'
}

case_dir=$(run_send MainThread copilot)
expect_code 0 "$(cat "$case_dir/rc")" "an explicit copilot target with no meta should confirm its empty rule-box composer"
grep -q 'unconfirmed' "$case_dir/err" && \
  fail "explicit copilot send: unconfirmed text present despite an empty composer"$'\n'"$(cat "$case_dir/err")"
[ "$(enter_count "$case_dir")" = 1 ] || \
  fail "explicit copilot send: expected one Enter, got $(enter_count "$case_dir")"$'\n'"$(cat "$case_dir/tmux.log")"
pass "fm-send: a meta-less explicit copilot target confirms its empty composer"

case_dir=$(run_send bash bash)
code=$(cat "$case_dir/rc")
[ "$code" != 0 ] || fail "an explicit non-copilot target must not read the copilot composer: exit 0"
pass "fm-send: a meta-less non-copilot explicit target keeps the shared reader"
