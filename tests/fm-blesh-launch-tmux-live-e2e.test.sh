#!/usr/bin/env bash
# Token-free live regression for worker launch through real tmux and ble.sh.
#
# The test runs the public fm-spawn.sh path repeatedly against a private tmux
# server, a real linked worktree, an interactive Bash line editor with ble.sh,
# a nested Treehouse-shaped shell transition, and a fake Pi only at the final
# process boundary. Half the runs delay shell startup so input queues while the
# editor is busy. Set FM_BLESH_TMUX_REPEATS to change the default 50 runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_BLESH_TMUX_LAUNCH_LIVE_E2E tmux blesh-share git bash

TMP_ROOT=$(fm_test_tmproot fm-blesh-launch-tmux-live)
REAL_TMUX=$(command -v tmux)
REAL_BASH=$(command -v bash)
BLESH_SHARE=$(blesh-share)
SOCKET="fm-blesh-launch-$$"
SHIM="$TMP_ROOT/shim"
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/worktree"
MARKERS="$TMP_ROOT/markers"
RCFILE="$TMP_ROOT/bashrc"
SHELL_WRAPPER="$TMP_ROOT/interactive-bash"
REPEATS=${FM_BLESH_TMUX_REPEATS:-50}

case "$REPEATS" in
  ''|*[!0-9]*) fail "FM_BLESH_TMUX_REPEATS must be a positive integer" ;;
  0) fail "FM_BLESH_TMUX_REPEATS must be a positive integer" ;;
esac
[ -f "$BLESH_SHARE/ble.sh" ] || fail "blesh-share did not resolve a ble.sh installation"
mkdir -p "$SHIM" "$MARKERS"

cleanup_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_live EXIT

cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
cat > "$SHELL_WRAPPER" <<EOF
#!/usr/bin/env bash
exec "$REAL_BASH" --noprofile --rcfile "$RCFILE" -i
EOF
cat > "$RCFILE" <<EOF
if [ "\${FM_BLESH_BUSY:-0}" = 1 ]; then
  sleep 0.4
fi
. "$BLESH_SHARE/ble.sh" --noattach
ble-attach
PS1='fm-blesh-test$ '
EOF
cat > "$SHIM/treehouse" <<'SH'
#!/usr/bin/env bash
cd "${FM_BLESH_WORKTREE:?}" || exit 1
exec "${SHELL:?}"
SH
cat > "$SHIM/pi" <<'SH'
#!/usr/bin/env bash
mkdir -p "${FM_BLESH_MARKERS:?}"
printf 'started\n' > "$FM_BLESH_MARKERS/${FM_TASK_ID:?}"
SH
chmod +x "$SHIM/tmux" "$SHELL_WRAPPER" "$SHIM/treehouse" "$SHIM/pi"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'pi\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"
git init -q "$PROJ_DIR"
git -C "$PROJ_DIR" config user.email test@example.invalid
git -C "$PROJ_DIR" config user.name test
touch "$PROJ_DIR/seed"
git -C "$PROJ_DIR" add seed
git -C "$PROJ_DIR" commit -qm seed
git -C "$PROJ_DIR" worktree add -q -b live-worktree "$WT_DIR"

PATH="$SHIM:$PATH" SHELL="$SHELL_WRAPPER" FM_BLESH_WORKTREE="$WT_DIR" \
  FM_BLESH_MARKERS="$MARKERS" tmux new-session -d -s firstmate -x 120 -y 40

run_one() {  # <ordinal> <busy 0|1>
  local ordinal=$1 busy=$2 id out status capture i=0
  id="blesh-tmux-$ordinal"
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise token-free worker launch through tmux and ble.sh.

## Firstmate spec
Start the fake worker and change no files.
EOF
  PATH="$SHIM:$PATH" tmux set-environment -g FM_BLESH_BUSY "$busy"
  out=$(env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BLESH_WORKTREE="$WT_DIR" FM_BLESH_MARKERS="$MARKERS" \
    SHELL="$SHELL_WRAPPER" PATH="$SHIM:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --scout --harness pi --backend tmux 2>&1)
  status=$?
  expect_code 0 "$status" "tmux ble.sh spawn $ordinal should return success"
  while [ "$i" -lt 100 ] && [ ! -f "$MARKERS/$id" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -f "$MARKERS/$id" ]; then
    capture=$(PATH="$SHIM:$PATH" tmux capture-pane -p -t "firstmate:fm-$id" -S -200 2>/dev/null || true)
    case "$capture" in
      *'-- MULTILINE --'*) fail "tmux ble.sh spawn $ordinal entered multiline mode" ;;
    esac
    fail "tmux ble.sh spawn $ordinal did not start the fake worker: $out"
  fi
  PATH="$SHIM:$PATH" tmux kill-window -t "firstmate:fm-$id" >/dev/null 2>&1 \
    || fail "could not remove tmux test window $ordinal"
}

ordinal=1
idle=$((REPEATS / 2))
[ "$idle" -gt 0 ] || idle=1
while [ "$ordinal" -le "$REPEATS" ]; do
  if [ "$ordinal" -le "$idle" ]; then busy=0; else busy=1; fi
  run_one "$ordinal" "$busy"
  ordinal=$((ordinal + 1))
done

pass "real tmux and ble.sh executed $REPEATS/$REPEATS complete token-free worker launches across settled and busy shells"
