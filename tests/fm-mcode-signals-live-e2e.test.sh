#!/usr/bin/env bash
# Credentialed MiniMax Code (mcode) worker guard. Opt in with FM_MCODE_SIGNALS_LIVE=1.
# FM_MCODE_MODEL chooses a configured <provider>/<model> id (default
# minimax/MiniMax-M3.1-Flash). FM_MCODE_LIVE_BACKEND selects tmux (default) or
# herdr; herdr runs in a named non-default lab session through
# bin/fm-herdr-lab.sh and verifies the live default session is untouched.
# The launch is bin/fm-spawn.sh's own generated command on a private server;
# only worktree allocation is a stub. Steering, interrupt, exit, and relaunch
# use the real Firstmate control plane. The run uses the caller's own MiniMax
# sign-in and spends a few small prompts of its plan; it needs the captain's
# global Full access, which it reads and never writes.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_MCODE_SIGNALS_LIVE mcode tmux jq git
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

MCODE_BIN=$(command -v mcode)
VERSION="mcode $("$MCODE_BIN" --version 2>/dev/null | head -1)"
MODEL=${FM_MCODE_MODEL:-minimax/MiniMax-M3.1-Flash}
BACKEND=${FM_MCODE_LIVE_BACKEND:-tmux}
REAL_TMUX=$(command -v tmux)
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_TMUX_DIR=
HERDR_LAB_SESSION=
ID=mcode-live
LAB=

fail() {
  printf 'not ok - %s [%s]: %s\n' "$VERSION" "$BACKEND" "$1" >&2
  if [ -n "${TARGET:-}" ]; then
    printf '# last screen rows:\n' >&2
    fm_backend_capture "$BACKEND" "$TARGET" 60 2>/dev/null | grep -v '^[[:space:]]*$' | tail -25 | sed 's/^/# /' >&2
  fi
  exit 1
}
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fi
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
  fi
  if [ -n "$LAB" ]; then
    "$LAB_HOME_HELPER" teardown "$LAB/fm" >/dev/null 2>&1 || true
    chmod -R u+w "$LAB" 2>/dev/null
    rm -rf -- "$LAB"
  fi
  exit "$status"
}

case "$BACKEND" in
  tmux) ;;
  herdr) command -v herdr >/dev/null 2>&1 || fail 'FM_MCODE_LIVE_BACKEND=herdr but herdr is not installed' ;;
  *) fail "FM_MCODE_LIVE_BACKEND must be tmux or herdr, not '$BACKEND'" ;;
esac
# A guard that cannot launch checks nothing: an unready account is a failure
# naming the fix, never a pass.
"$ROOT/bin/fm-mcode-config.sh" preflight "$MODEL" || fail 'the mcode launch preflight refused'

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-mcode-live.XXXXXX") || fail 'could not create the lab'
LAB=$(cd "$LAB" && pwd -P)
trap cleanup EXIT
H="$LAB/fm"
PROJ="$LAB/project"
WT="$LAB/wt"
"$LAB_HOME_HELPER" create "$H" >/dev/null || fail 'could not mark the lab home'
fm_test_spawn_home "$H" mcode
printf '%s\n' "$BACKEND" > "$H/config/backend"
printf 'manual\n' > "$H/config/backlog-backend"
fm_git_init_commit "$PROJ"
git clone -q "$PROJ" "$WT" || fail 'could not prepare the scratch clone'
git -C "$WT" checkout -qb mcode-live || fail 'could not branch the scratch clone'
git -C "$WT" config user.name 'mcode live guard'
git -C "$WT" config user.email mcode-live-guard@example.invalid
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run 'bash $ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work, do not delegate, start no background task, and do not poll for anything: end your turn as soon as those files exist."

# The pane's `treehouse get` enters the prepared clone in a subshell exactly as
# the real tool does, so no worktree pool is touched.
mkdir -p "$LAB/bin"
# shellcheck disable=SC2016 # the single-quoted shim expands its own argument
printf '#!/bin/sh\n[ "${1:-}" = get ] || exit 0\ncd "%s" && exec /bin/bash --noprofile --norc\n' "$WT" > "$LAB/bin/treehouse"
chmod +x "$LAB/bin/treehouse"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset HERDR_ENV HERDR_PANE_ID HERDR_BIN_PATH
if [ "$BACKEND" = tmux ]; then
  LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$H") || fail 'could not isolate tmux'
  export TMUX_TMPDIR="$LAB_TMUX_DIR"
  tmux -f /dev/null new-session -d -s firstmate -n lab -x 160 -y 50 "/bin/bash --noprofile --norc" \
    || fail 'could not start the isolated tmux server'
  tmux set-option -g default-command "/bin/bash --noprofile --norc" >/dev/null \
    || fail 'could not pin the lab shell'
else
  HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "$ID") || fail 'could not name the Herdr lab'
  # A Herdr pane runs the operator's login shell, whose profile puts the real
  # treehouse first on PATH; a POSIX sh login reads $ENV after the profile, so
  # the lab server's panes resolve the stub first without touching HOME, which
  # mcode's sign-in and the lab helper's tripwire both depend on.
  # shellcheck disable=SC2016 # $PATH expands in the lab shell that sources it
  printf 'PATH="%s:$PATH"; export PATH\n' "$LAB/bin" > "$LAB/shenv"
  SHELL=/bin/sh ENV="$LAB/shenv" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null \
    || fail 'could not provision the Herdr lab'
  # Firstmate's Herdr backend passes --session explicitly on every call; this
  # only selects which session it resolves.
  export HERDR_SESSION="$HERDR_LAB_SESSION"
fi

META="$H/state/$ID.meta"
meta_value() { awk -F= -v k="$1" '$1 == k { v = substr($0, index($0, "=") + 1) } END { print v }' "$META"; }
wait_file() {
  local path=$1
  for _ in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}"
}
busy() { fm_busy_classify "$BACKEND" "$TARGET" mcode "$ID" "$H/state"; }
wait_busy_state() {  # <expected> <what>
  for _ in $(seq 1 480); do [ "$(busy)" = "$1" ] && return 0; sleep 0.5; done
  fail "$2 (last '$(busy)')"
}
screen_text() { fm_backend_capture "$BACKEND" "$TARGET" 200 2>/dev/null || true; }

FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness mcode --model "$MODEL" \
  > "$LAB/spawn.log" 2>&1 || fail "fm-spawn's generated mcode launch failed: $(cat "$LAB/spawn.log")"
TARGET=$(meta_value window)
[ -n "$TARGET" ] || fail 'the spawn recorded no endpoint'
[ "$(meta_value harness)" = mcode ] || fail 'the spawn did not record harness=mcode'
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = mcode ] || fail "tool ancestry did not identify mcode: $(cat "$WT/harness.txt")"
wait_busy_state 'idle mcode-title' 'the finished brief turn did not read idle from the title'
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = alive ] || fail 'the live mcode worker is not classified alive'
expect_model=${MODEL#*/}
expect_model=${expect_model#MiniMax-}
screen_text | grep -q "✦ $expect_model" || fail "the status row does not show the requested model $MODEL"
pass "$VERSION [$BACKEND]: spawn brief, Full access, model $MODEL, identity, and title idle"

git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by|generated with' "$LAB/commit.txt" \
  || fail "worker commit carries attribution: $(cat "$LAB/commit.txt")"
pass "$VERSION [$BACKEND]: the worker commit carries no attribution"

verdict=$(fm_backend_composer_state "$BACKEND" "$TARGET")
[ "$verdict" = empty ] || fail "idle composer was $verdict"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' \
  > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_busy_state 'idle mcode-title' 'the steered turn did not settle'
pass "$VERSION [$BACKEND]: real fm-send doorbell read and acknowledged"

# An idle interrupt is one Escape: it must not open the edit-message mode that
# a second fast Escape would, its Ctrl+U leaves the composer empty, and the
# agent stays.
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
sleep 1
! screen_text | grep -q 'Editing the selected message' || fail 'an idle interrupt left the edit-message mode open'
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = alive ] || fail 'an idle interrupt stopped the agent'
verdict=$(fm_backend_composer_state "$BACKEND" "$TARGET")
[ "$verdict" = empty ] || fail "the composer after an idle interrupt was $verdict"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool and wait for it to finish. Do not respond before it finishes.' \
  > "$LAB/send.log" 2>&1 || fail 'could not steer the interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(busy)" = 'busy mcode-title' ] && screen_text | fm_busy_mcode_tail_busy; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'the title and the spinner row did not both read busy during the probe'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
for _ in $(seq 1 60); do screen_text | grep -q 'Interrupted after' && break; sleep 0.5; done
screen_text | grep -q 'Interrupted after' || fail 'a single Escape did not cancel the running turn'
wait_busy_state 'idle mcode-title' 'the interrupted turn did not settle'
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = alive ] || fail 'the interrupt stopped the agent'
# mcode restores a prompt whose turn produced nothing yet; the interrupt's
# Ctrl+U must leave the composer empty either way, or the next line concatenates.
verdict=$(fm_backend_composer_state "$BACKEND" "$TARGET")
[ "$verdict" = empty ] || fail "the composer after a busy interrupt was $verdict"
pass "$VERSION [$BACKEND]: one Escape cancels the turn, keeps the agent, and the title settles"

"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = dead ] || fail '/quit did not return to the shell'
screen_text | grep -q 'mcode --session mvs_' || fail 'the exit summary did not print the session resume command'
pass "$VERSION [$BACKEND]: /quit exits and prints mcode --session <id>"

rm -f "$WT/answer.txt" "$WT/harness.txt"
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Runtime relaunch verification: the previous worker was exited on purpose; redo the brief exactly as written.' > "$LAB/relaunch.log" 2>&1 || fail "relaunch failed: $(cat "$LAB/relaunch.log")"
TARGET=$(meta_value window)
wait_file "$WT/harness.txt"
wait_busy_state 'idle mcode-title' 'the relaunched worker did not settle'
[ "$(fm_backend_agent_state "$BACKEND" "$TARGET")" = alive ] || fail 'the relaunched worker is not alive'
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "final exit failed: $(cat "$LAB/exit.log")"
pass "$VERSION [$BACKEND]: relaunch re-delivers the brief and the worker exits again"
