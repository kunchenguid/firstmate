#!/usr/bin/env bash
# bin/fm-secondmate-rotate.sh: second-mate session rotation.
#
# What these pin, through the executable interface the watcher calls:
#   1. tokens: a Pi mate's size is its newest session's last assistant usage,
#      a Claude mate's is its newest transcript's prompt usage, and anything
#      else is `unmeasured`.
#   2. scan: off without config/secondmate-rotation; with it, only an idle,
#      local mate at or above the threshold is rotated - through
#      fm-secondmate-restart.sh --rotate, started detached - and at most once per
#      window, whatever the outcome.
#   3. The watcher's check sweep runs the scan only with the gate present and
#      queues each rotation as a `check: secondmate-rotation` wake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROTATE="$ROOT/bin/fm-secondmate-rotate.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-rotate)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

new_case() {  # <name> -> case dir with a home, agent dirs, and a restart stub
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/pi" "$dir/claude" "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
target=
prev=
for arg in "$@"; do
  [ "$prev" = -t ] && target=$arg
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*)
        if [ -f "$FM_ROTATE_CASE_DIR/cmd.${target##*:}" ]; then
          cat "$FM_ROTATE_CASE_DIR/cmd.${target##*:}"
        else
          printf 'pi\n'
        fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
  list-windows)
    for meta in "$FM_HOME"/state/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      printf 'fm-%s\n' "${id%.meta}"
    done
    ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  cat > "$dir/restart-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/restarts"
SH
  chmod +x "$dir/restart-stub"
  printf '%s\n' "$dir"
}

# add_mate <case> <id> <harness> <tokens|none> [busy|idle] [extra meta line]
add_mate() {
  local dir=$1 id=$2 harness=$3 tokens=$4 busy=${5:-idle} extra=${6:-}
  local mhome="$dir/homes/$id" sdir
  mkdir -p "$mhome"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "home=$mhome"
    echo "worktree=$mhome"
    [ -z "$extra" ] || echo "$extra"
  } > "$dir/home/state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" --state "$busy" --source fm-spawn --event seed >/dev/null
  [ "$tokens" != none ] || return 0
  case "$harness" in
    pi)
      sdir="$dir/pi/sessions/--$(printf '%s' "${mhome#/}" | tr '/' '-')--"
      mkdir -p "$sdir"
      # An older session, then the live one whose LAST sized reply counts; a
      # failed reply records zero usage and must not mask it.
      printf '%s\n' '{"type":"message","message":{"role":"assistant","usage":{"totalTokens":999999}}}' \
        > "$sdir/2026-01-01T00-00-00-000Z_old.jsonl"
      touch -t 202601010000 "$sdir/2026-01-01T00-00-00-000Z_old.jsonl"
      {
        printf '%s\n' '{"type":"session","cwd":"x"}'
        printf '%s\n' '{"type":"message","message":{"role":"assistant","usage":{"totalTokens":1000}}}'
        printf '%s\n' '{"type":"message","message":{"role":"user","content":"hi"}}'
        printf '{"type":"message","message":{"role":"assistant","usage":{"input":10,"output":5,"cacheRead":%s,"cacheWrite":0,"totalTokens":%s}}}\n' "$((tokens - 15))" "$tokens"
        printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"error","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0}}}'
      } > "$sdir/2026-02-01T00-00-00-000Z_live.jsonl"
      ;;
    claude)
      sdir="$dir/claude/projects/$(printf '%s' "$mhome" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
      mkdir -p "$sdir"
      printf '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":9}}}\n' "$((tokens - 5))" \
        > "$sdir/session.jsonl"
      ;;
  esac
}

run_rotate() {  # <case> <args...>
  local dir=$1; shift
  run_rotate_with_command "$dir" "$dir/restart-stub" "$@"
}

run_rotate_with_command() {  # <case> <command> <args...>
  local dir=$1 cmd=$2; shift 2
  env PATH="$dir/fakebin:$PATH" FM_ROTATE_CASE_DIR="$dir" \
    FM_HOME="$dir/home" PI_CODING_AGENT_DIR="$dir/pi" CLAUDE_CONFIG_DIR="$dir/claude" \
    FM_SECONDMATE_ROTATE_RESTART="$cmd" \
    bash "$ROTATE" "$@" 2>&1
}

wait_restarts() {  # <case> <count>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(wc -l < "$1/restarts" 2>/dev/null | tr -d ' ')" = "$2" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_tokens_reads_each_measured_harness() {
  local dir
  dir=$(new_case tokens)
  add_mate "$dir" smp pi 312345
  add_mate "$dir" smc claude 270000
  add_mate "$dir" smx codex none
  add_mate "$dir" smn pi none
  [ "$(run_rotate "$dir" tokens smp)" = 312345 ] \
    || fail "a Pi mate's size is its newest session's last sized reply, got: $(run_rotate "$dir" tokens smp)"
  [ "$(run_rotate "$dir" tokens smc)" = 270000 ] \
    || fail "a Claude mate's size is its prompt usage, got: $(run_rotate "$dir" tokens smc)"
  [ "$(run_rotate "$dir" tokens smx)" = unmeasured ] || fail "an unmeasured harness must say so"
  [ "$(run_rotate "$dir" tokens smn)" = unmeasured ] || fail "a Pi mate with no session must be unmeasured"
  pass "fm-secondmate-rotate tokens: Pi and Claude transcripts are measured, everything else is unmeasured"
}

test_bound_herdr_id_selects_exact_session() {
  local dir out sdir
  dir=$(new_case bound-id)
  add_mate "$dir" bound pi 900000
  sed -i.bak 's/^window=.*/window=herdr-session:pane-1/; $a backend=herdr' "$dir/home/state/bound.meta"
  printf '%s\n' '{"type":"message","message":{"role":"assistant","usage":{"totalTokens":300000}}}' \
    > "$dir/pi/sessions/--$(printf '%s' "${dir#/}/homes/bound" | tr '/\\:' '---')--/chat_bound-id.jsonl"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"agent":{"agent":"pi","agent_session":{"kind":"id","value":"bound-id"}}}}'
SH
  chmod +x "$dir/fakebin/herdr"
  out=$(run_rotate "$dir" tokens bound)
  [ "$out" = 300000 ] || fail "a bound bare session id must select its exact transcript, got: $out"
  printf '%s\n' '{"id":"bound-id"}' '{"type":"message","message":{"role":"assistant","usage":{"totalTokens":400000}}}' \
    > "$dir/pi/sessions/--$(printf '%s' "${dir#/}/homes/bound" | tr '/\\:' '---')--/declared.jsonl"
  out=$(run_rotate "$dir" tokens bound)
  [ "$out" = unmeasured ] || fail "ambiguous bound session matches must stay unmeasured, got: $out"
  pass "fm-secondmate-rotate tokens: Herdr bare IDs select exact, unambiguous Pi transcripts"
}

test_scan_rotates_only_due_mates_once_per_window() {
  local dir out
  dir=$(new_case scan)
  add_mate "$dir" big pi 300000
  add_mate "$dir" dead pi 300000
  printf 'zsh\n' > "$dir/cmd.fm-dead"
  add_mate "$dir" small pi 100000
  add_mate "$dir" busy pi 900000 busy
  add_mate "$dir" far pi 900000 idle "remote_host=elsewhere"

  out=$(run_rotate "$dir" scan)
  [ -z "$out" ] && [ ! -e "$dir/restarts" ] \
    || fail "rotation must stay off without config/secondmate-rotation, got: $out"

  : > "$dir/home/config/secondmate-rotation"
  out=$(run_rotate "$dir" scan)
  assert_contains "$out" "rotating big: context 300000 tokens >= 250000" "the idle oversized mate should be rotated"
  [ "$(printf '%s\n' "$out" | grep -c '^rotating ')" = 1 ] \
    || fail "a small, busy, or remote mate must not be rotated, got: $out"
  assert_not_contains "$out" "rotating dead:" \
    "a dead shell with stale idle state must not be rotated"
  wait_restarts "$dir" 1 || fail "the detached restart was never started"
  [ "$(cat "$dir/restarts")" = "--rotate big" ] \
    || fail "rotation must run the guarded restart in rotate mode, got: $(cat "$dir/restarts")"
  assert_grep 'tokens=300000' "$dir/home/state/big.rotation" "the rotation should be recorded before it starts"

  out=$(run_rotate "$dir" scan)
  [ -z "$out" ] || fail "a mate must not be rotated twice inside its window, got: $out"

  printf 'threshold-tokens=90000\nwindow-seconds=1\n' > "$dir/home/config/secondmate-rotation"
  sed -i.bak 's/^epoch=.*/epoch=1/' "$dir/home/state/big.rotation"
  out=$(run_rotate "$dir" scan)
  assert_contains "$out" "rotating big:" "a mate whose window elapsed is due again"
  assert_contains "$out" "rotating small: context 100000 tokens >= 90000" "a configured threshold should apply"
  pass "fm-secondmate-rotate scan: only idle local mates past the threshold, at most once per window"
}

test_invalid_restart_does_not_consume_rotation_window() {
  local dir out
  dir=$(new_case invalid-restart)
  add_mate "$dir" big pi 300000
  : > "$dir/home/config/secondmate-rotation"
  out=$(run_rotate_with_command "$dir" "$dir/does-not-exist" scan)
  assert_contains "$out" "could not start secondmate rotation for big" \
    "an invalid restart command should report the failed launch"
  [ ! -e "$dir/home/state/big.rotation" ] \
    || fail "a failed rotation launch must not leave a window record behind"
  out=$(run_rotate_with_command "$dir" "$dir/does-not-exist" scan)
  assert_contains "$out" "could not start secondmate rotation for big" \
    "a failed rotation should remain eligible for retry"
  [ ! -e "$dir/home/state/big.rotation" ] \
    || fail "a retry after a failed rotation must not be suppressed by stale state"
  pass "fm-secondmate-rotate scan: an invalid restart command does not consume a rotation window"
}

test_watcher_sweep_queues_the_rotation() {
  local dir rc
  dir=$(new_case watch)
  add_mate "$dir" big pi 300000
  : > "$dir/home/config/secondmate-rotation"
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$dir/home/state/z-stop.check.sh"
  chmod 0700 "$dir/home/state/z-stop.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null || fail "could not register the stop check"
  timeout 60 env PATH="$dir/fakebin:$PATH" FM_ROTATE_CASE_DIR="$dir" \
    FM_HOME="$dir/home" PI_CODING_AGENT_DIR="$dir/pi" CLAUDE_CONFIG_DIR="$dir/claude" \
    FM_SECONDMATE_ROTATE_RESTART="$dir/restart-stub" FM_BACKEND=tmux \
    FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err"; rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher failed: $(cat "$dir/watch.err")"
  grep -F 'check: secondmate-rotation: rotating big: context 300000 tokens' "$dir/home/state/.wake-queue" >/dev/null \
    || fail "the rotation was not queued as a wake: $(cat "$dir/home/state/.wake-queue" 2>/dev/null)"
  wait_restarts "$dir" 1 || fail "the watcher sweep never started the restart"
  pass "fm-secondmate-rotate: the watcher sweep rotates a due mate and queues one wake"
}

test_tokens_reads_each_measured_harness
test_bound_herdr_id_selects_exact_session
test_scan_rotates_only_due_mates_once_per_window
test_invalid_restart_does_not_consume_rotation_window
test_watcher_sweep_queues_the_rotation
