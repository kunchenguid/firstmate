#!/usr/bin/env bash
# Regression coverage for launch/steer submission handshakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-send-handshake)

make_submit_fake_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?}
composer=${FM_FAKE_COMPOSER:?}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-$PWD}"; exit 0 ;;
        '#S') printf 'firstmate\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  capture-pane)
    if [ "${*: -1}" = "-40" ] || [ -n "${FM_FAKE_BUSY_TAIL:-}" ]; then
      printf '%s\n' "${FM_FAKE_BUSY_TAIL:-}"
      exit 0
    fi
    cat "$composer"
    exit 0 ;;
  send-keys)
    printf '%s\n' "$*" >> "$log"
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf '%s\n' "$1" > "$composer"; shift ;;
        Enter)
          if [ -n "${FM_FAKE_BUSY_AFTER_ENTER:-}" ]; then
            printf 'Working...\n' > "$composer"
          else
            printf '\033[1m\xe2\x80\xba\033[0m \033[2mExplain this codebase\033[0m\n' > "$composer"
          fi
          shift ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_spawn_fake_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?}
composer=${FM_FAKE_COMPOSER:?}
case "${1:-}" in
  has-session|new-session|new-window)
    printf '%s\n' "$*" >> "$log"
    exit 0 ;;
  list-windows)
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_current_path*) printf '%s\n' "${FM_FAKE_WORKTREE:?}"; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  capture-pane)
    cat "$composer"
    exit 0 ;;
  send-keys)
    printf '%s\n' "$*" >> "$log"
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf '%s\n' "$1" > "$composer"; touch "${FM_FAKE_LAUNCH_TYPED:-/dev/null}"; shift ;;
        Enter)
          if [ -n "${FM_FAKE_LAUNCH_TYPED:-}" ] && [ -e "$FM_FAKE_LAUNCH_TYPED" ] && [ -z "${FM_FAKE_KEEP_LAUNCH_PENDING:-}" ]; then
            printf 'Working...\n' > "$composer"
          fi
          shift ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

test_fm_send_accepts_codex_idle_prompt_after_submit() {
  local dir home fakebin log composer err
  dir="$TMP_ROOT/send-codex-idle"; mkdir -p "$dir"
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; composer="$dir/composer"; err="$dir/send.err"
  printf '\033[1m\xe2\x80\xba\033[0m \033[2mExplain this codebase\033[0m\n' > "$composer"
  fakebin=$(make_submit_fake_tmux "$dir")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$composer" \
    FM_SEND_SLEEP=0.01 "$SEND" sess:win 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send reported a false swallowed Enter on codex idle prompt: $(cat "$err")"
  pass "fm-send accepts codex idle/ghost prompt as submitted"
}

test_fm_send_refuses_busy_pane_without_typing() {
  local dir home fakebin log composer err
  dir="$TMP_ROOT/send-busy"; mkdir -p "$dir"
  home="$dir/home"; mkdir -p "$home/state"
  log="$dir/tmux.log"; composer="$dir/composer"; err="$dir/send.err"
  : > "$log"
  printf '\033[1m\xe2\x80\xba\033[0m\n' > "$composer"
  fakebin=$(make_submit_fake_tmux "$dir")
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$composer" \
    FM_FAKE_BUSY_TAIL="esc to interrupt" FM_SEND_SLEEP=0.01 \
    "$SEND" sess:win 'do not queue this while busy' >/dev/null 2>"$err"; then
    fail "fm-send exited zero for a busy pane"
  fi
  assert_contains "$(cat "$err")" "target pane busy" "fm-send did not explain busy target refusal"
  assert_not_contains "$(cat "$log")" "send-keys -t sess:win -l" "fm-send typed steering text into a busy pane"
  pass "fm-send refuses a busy pane without typing into the composer"
}

test_fm_spawn_refuses_success_when_launch_text_remains_pending() {
  local dir home project worktree fakebin log composer err out status
  dir="$TMP_ROOT/spawn-pending"; home="$dir/home"; project="$home/projects/alpha"; worktree="$dir/worktree"
  mkdir -p "$home/data/spawn-pending" "$home/state" "$project" "$worktree"
  fm_git_init_commit "$worktree"
  printf 'brief\n' > "$home/data/spawn-pending/brief.md"
  log="$dir/tmux.log"; composer="$dir/composer"; err="$dir/spawn.err"; out="$dir/spawn.out"
  : > "$composer"
  fakebin=$(make_spawn_fake_tmux "$dir")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$composer" \
    FM_FAKE_WORKTREE="$worktree" FM_FAKE_LAUNCH_TYPED="$dir/launch-typed" FM_FAKE_KEEP_LAUNCH_PENDING=1 \
    "$SPAWN" spawn-pending projects/alpha codex >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn printed success while launch text was still pending"
  assert_not_contains "$(cat "$out")" "spawned spawn-pending" "fm-spawn reported spawned despite pending launch"
  assert_contains "$(cat "$err")" "launch command was not submitted" "fm-spawn did not explain pending launch text"
  pass "fm-spawn fails instead of reporting success when launch submission stays pending"
}

test_fm_spawn_reports_success_when_launch_submits_and_pane_busy() {
  local dir home project worktree fakebin log composer err out
  dir="$TMP_ROOT/spawn-busy"; home="$dir/home"; project="$home/projects/alpha"; worktree="$dir/worktree"
  mkdir -p "$home/data/spawn-busy" "$home/state" "$project" "$worktree"
  fm_git_init_commit "$worktree"
  printf 'brief\n' > "$home/data/spawn-busy/brief.md"
  log="$dir/tmux.log"; composer="$dir/composer"; err="$dir/spawn.err"; out="$dir/spawn.out"
  : > "$composer"
  fakebin=$(make_spawn_fake_tmux "$dir")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$composer" \
    FM_FAKE_WORKTREE="$worktree" FM_FAKE_LAUNCH_TYPED="$dir/launch-typed" \
    "$SPAWN" spawn-busy projects/alpha codex >"$out" 2>"$err" \
    || fail "fm-spawn failed after launch submission made pane busy: $(cat "$err")"
  assert_contains "$(cat "$out")" "spawned spawn-busy" "fm-spawn did not report success after busy launch"
  pass "fm-spawn reports success after launch command submits and pane is busy"
}

test_fm_send_accepts_codex_idle_prompt_after_submit
test_fm_send_refuses_busy_pane_without_typing
test_fm_spawn_refuses_success_when_launch_text_remains_pending
test_fm_spawn_reports_success_when_launch_submits_and_pane_busy
