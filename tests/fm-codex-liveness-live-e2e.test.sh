#!/usr/bin/env bash
# Opt-in credentialed Codex liveness guard.
#
# The portable busy-state tests pin the parser, deadline fold, and generated
# launch shape. This guard drives the exact launch command fm-spawn generated
# through a real Codex TUI on a private tmux server, then reads the result only
# through fm-crew-state. It proves a successful turn, an API error, and a
# manual interruption because the two negative paths are where Codex emits no
# Stop and the deadline must surface the worker.
set -u

if [ "${FM_CODEX_LIVENESS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVENESS_LIVE_E2E=1 to run the real Codex liveness guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

CODEX_BIN=$(command -v codex 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
[ -x "$CODEX_BIN" ] || fail "FM_CODEX_LIVENESS_LIVE_E2E=1 but codex is not installed"
[ -x "$REAL_TMUX" ] || fail "FM_CODEX_LIVENESS_LIVE_E2E=1 but tmux is not installed"

CODEX_VERSION=$($CODEX_BIN --version 2>/dev/null || true)
fm_busy_codex_hooks_verified \
  || fail "installed Codex is outside the verified from-0.147.0 version gate: ${CODEX_VERSION:-unreadable}"

LAB=$(fm_test_tmproot fm-codex-liveness-live) || fail "could not create Codex liveness lab"
HOME_DIR="$LAB/home"
FAKEBIN="$LAB/fakebin"
LIVEBIN="$LAB/livebin"
SOCKET="fm-codex-liveness-$$"
SESSION=codex-liveness
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN" "$LIVEBIN"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"

cleanup_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap 'cleanup_live; fm_test_cleanup' EXIT
trap 'cleanup_live; fm_test_cleanup; exit 130' INT
trap 'cleanup_live; fm_test_cleanup; exit 143' TERM

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    case " $* " in
      *' -l '*) printf '%s\n' "${@: -1}" > "$FM_FAKE_TMUX_LAUNCH" ;;
    esac
    exit 0
    ;;
  has-session|new-session|new-window|set-window-option|kill-window) exit 0 ;;
esac
exit 0
SH
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/treehouse"

cat > "$LIVEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$LIVEBIN/codex" <<SH
#!/usr/bin/env bash
exec "$CODEX_BIN" "\$@"
SH
cat > "$LIVEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$LIVEBIN/tmux" "$LIVEBIN/codex" "$LIVEBIN/no-mistakes"

generate_launch() {  # <id> <brief> <deadline-secs> [model]
  local id=$1 brief=$2 deadline=$3 model=${4-} out project wt
  project="$LAB/$id/project"
  wt="$LAB/$id/wt"
  fm_git_worktree "$project" "$wt" "fm/$id-live"
  printf '%s\n' "$wt" > "$HOME_DIR/$id.worktree"
  mkdir -p "$HOME_DIR/data/$id"
  printf '%s\n' "$brief" > "$HOME_DIR/data/$id/brief.md"
  if [ -n "$model" ]; then
    out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
      FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LAUNCH="$HOME_DIR/$id.launch" \
      FM_BUSY_CODEX_TURN_DEADLINE_SECS="$deadline" TMUX="fake,1,0" \
      PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$project" \
      --harness codex --model "$model" --mode no-mistakes --yolo off 2>&1) \
      || fail "fm-spawn could not generate $id: $out"
  else
    out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
      FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LAUNCH="$HOME_DIR/$id.launch" \
      FM_BUSY_CODEX_TURN_DEADLINE_SECS="$deadline" TMUX="fake,1,0" \
      PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$project" \
      --harness codex --mode no-mistakes --yolo off 2>&1) \
      || fail "fm-spawn could not generate $id: $out"
  fi
  [ -s "$HOME_DIR/$id.launch" ] || fail "fm-spawn captured no launch for $id"
  sed -E "s|^window=.*$|window=$SESSION:$id|" "$HOME_DIR/state/$id.meta" \
    > "$HOME_DIR/state/$id.meta.live"
  mv "$HOME_DIR/state/$id.meta.live" "$HOME_DIR/state/$id.meta"
}

start_worker() {  # <id>
  local id=$1 launch wt pane i=0
  launch=$(cat "$HOME_DIR/$id.launch")
  wt=$(cat "$HOME_DIR/$id.worktree")
  if "$REAL_TMUX" -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$id" -c "$wt" "$launch" \
      || fail "could not launch real Codex worker $id"
  else
    "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n "$id" -c "$wt" "$launch" \
      || fail "could not launch real Codex worker $id"
  fi
  while [ "$i" -lt 100 ]; do
    pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:$id" -S -60 2>/dev/null || true)
    case "$pane" in
      *'Do you trust the contents of this directory?'*)
        "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$id" Enter
        return 0
        ;;
      *'OpenAI Codex (v'*) return 0 ;;
    esac
    sleep 0.2
    i=$((i + 1))
  done
  fail "real Codex worker $id showed neither its trust dialog nor its TUI"
}

record_field() {  # <id> <field-number>
  PATH="$LIVEBIN:$PATH" fm_busy_record_read "$HOME_DIR/state" "$1" 2>/dev/null | awk -v n="$2" '{print $n}'
}

wait_for_record() {  # <id> <state> <source> <event> [attempts]
  local id=$1 want_state=$2 want_source=$3 want_event=$4 attempts=${5:-300} i=0
  while [ "$i" -lt "$attempts" ]; do
    if [ "$(record_field "$id" 1)" = "$want_state" ] \
       && [ "$(record_field "$id" 2)" = "$want_source" ] \
       && [ "$(record_field "$id" 3)" = "$want_event" ]; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

crew_state() {  # <id>
  PATH="$LIVEBIN:$PATH" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-crew-state.sh" "$1"
}

wait_for_verdict() {  # <id> <fragment> [attempts]
  local id=$1 fragment=$2 attempts=${3:-300} i=0 out
  while [ "$i" -lt "$attempts" ]; do
    out=$(crew_state "$id")
    case "$out" in *"$fragment"*) printf '%s\n' "$out"; return 0 ;; esac
    sleep 0.2
    i=$((i + 1))
  done
  printf '%s\n' "$out"
  return 1
}

# Successful turn: observe the real open, then the real Stop and finished read.
generate_launch cx-success 'Reply exactly LIVE_SUCCESS and do nothing else.' 60
start_worker cx-success
wait_for_record cx-success busy codex-hook user-prompt-submit \
  || fail "real successful Codex worker emitted no UserPromptSubmit; record=$(cat "$HOME_DIR/state/cx-success.busy-state" 2>/dev/null || true); pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:cx-success" -S -80 2>/dev/null || true)"
out=$(crew_state cx-success)
assert_contains "$out" 'state: working' "real open Codex turn did not read working"
wait_for_record cx-success idle codex-hook stop \
  || fail "real successful Codex worker emitted no Stop"
printf 'done: real Codex turn completed successfully\n' > "$HOME_DIR/state/cx-success.status"
out=$(crew_state cx-success)
assert_contains "$out" 'state: done' "real successful Codex turn did not read done"
pass "real Codex success moved fm-crew-state from working to done"

# API error: the invalid model returns to the TUI with no Stop, so only the
# deadline may release the positive busy state.
generate_launch cx-api-error 'Reply SHOULD_NOT_SUCCEED.' 4 definitely-not-a-real-model-0815
start_worker cx-api-error
wait_for_record cx-api-error busy codex-hook user-prompt-submit \
  || fail "real API-error Codex worker emitted no UserPromptSubmit"
out=$(wait_for_verdict cx-api-error codex-deadline-expired 100) \
  || fail "API-error Codex turn did not surface on deadline: $out"
assert_contains "$out" 'state: unknown' "API-error deadline did not report unknown"
[ "$(record_field cx-api-error 3)" = user-prompt-submit ] \
  || fail "API-error path unexpectedly emitted a terminal hook"
pass "real Codex API error omitted Stop and surfaced on its deadline"

# Manual interruption: wait for the TUI's real working state, deliver the
# adapter-owned Escape, and prove the same missing-terminal deadline path.
generate_launch cx-interrupt 'Use the shell tool to run sleep 30, then reply exactly INTERRUPT_SHOULD_NOT_COMPLETE. Do nothing else.' 4
start_worker cx-interrupt
wait_for_record cx-interrupt busy codex-hook user-prompt-submit \
  || fail "real interrupted Codex worker emitted no UserPromptSubmit"
working_seen=0
for _ in $(seq 1 150); do
  pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:cx-interrupt" -S -80 2>/dev/null || true)
  case "$pane" in *'Working ('*) working_seen=1; break ;; esac
  sleep 0.2
done
[ "$working_seen" = 1 ] || fail "real Codex interrupt control never entered the TUI working state"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:cx-interrupt" Escape
sleep 1
[ "$(record_field cx-interrupt 3)" = user-prompt-submit ] \
  || fail "manual interruption unexpectedly emitted a terminal hook"
out=$(wait_for_verdict cx-interrupt codex-deadline-expired 100) \
  || fail "interrupted Codex turn did not surface on deadline: $out"
assert_contains "$out" 'state: unknown' "interrupted deadline did not report unknown"
pass "real Codex interruption omitted Stop and surfaced on its deadline"

cleanup_live
trap fm_test_cleanup EXIT
printf 'ok - %s live Codex liveness guard passed success, API-error, and interrupt controls\n' "$CODEX_VERSION"
