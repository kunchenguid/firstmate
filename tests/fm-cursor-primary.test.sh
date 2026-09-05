#!/usr/bin/env bash
# Behavior tests for Cursor Agent CLI as a firstmate PRIMARY
# (docs/turnend-guard.md, docs/sessionstart-nudge.md,
# docs/supervision-protocols/cursor.md).
#
# Four layers, all hermetic over temp dirs with real processes and NO cursor
# installed, so CI enforces them everywhere:
#   HOST GUARD  - bin/fm-hook-host-lib.sh, and each tracked Claude-shaped hook
#                 entrypoint standing down on a Cursor-delivered payload, which
#                 is what keeps a Cursor primary from running every covered
#                 event twice.
#   PARK        - bin/fm-turnend-guard-cursor.sh, the stop-hook park: its
#                 follow-up sources, its double loop bound, its bounded repair
#                 nag, and its post-claim supersession contract.
#   SESSION     - bin/fm-sessionstart-cursor.sh, which injects the digest at
#                 sessionStart.
#
# The park runs as a child of a fake harness (a bash symlink named cursor-agent)
# whose pid holds the fixture home's session lock, so the real Cursor ancestry
# path in bin/fm-session-lock-lib.sh is exercised rather than stubbed.
# tests/fm-cursor-primary-live-e2e.test.sh is the opt-in guard against a real
# cursor-agent. Neither replaces the other.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
# Use a real executable whose own canonical basename is cursor-agent. A symlink
# to bash is not sufficient on Linux: /proc resolves it to bash, so the real
# Cursor ancestry classifier correctly rejects that process as an impostor.
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake Cursor process"
cat > "$TMP_ROOT/fake-cursor.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
"$CC_BIN" -o "$FAKEBIN/cursor-agent" "$TMP_ROOT/fake-cursor.c" \
  || fail "could not build the fake Cursor process"
FAKE_CURSOR="$FAKEBIN/cursor-agent"

CURSOR_PAYLOAD='{"session_id":"sess-cursor","generation_id":"gen-1","loop_count":0,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}'
CLAUDE_STOP_PAYLOAD='{"session_id":"sess-claude","stop_hook_active":false}'

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard-cursor.sh fm-turnend-guard.sh fm-sessionstart-cursor.sh \
           fm-sessionstart-run.sh fm-sessionstart-nudge.sh fm-arm-pretool-check.sh \
           fm-cd-pretool-check.sh fm-claude-stop-autoarm.sh fm-hook-host-lib.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-gate-refuse-lib.sh fm-stdlib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir"/bin/*.sh
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# An arm fixture standing in for bin/fm-watch-arm.sh. Real process, real output.
write_arm_fixture() {  # <dir> <kind>
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win needs a look\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    switchable)
      # Slow until state/arm-fast appears, so a second invocation can be made
      # fast WITHOUT rewriting a script the first one is still executing.
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
if [ -e "$FM_HOME/state/arm-fast" ]; then
  printf 'stale: fixture-win fast\n'
  exit 0
fi
sleep 30
printf 'stale: fixture-win late\n'
exit 0
SH
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# The park's child body: claim the home lock as this fake harness process, then
# run the adapter as its child, so the real Cursor ancestry path decides lock
# ownership on every platform. Keep the fake harness process alive: Linux
# changes the process identity when an exec reaches the adapter's shebang.
PARK_CHILD='
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-turnend-guard-cursor.sh"
'

# Run the park as a child of the fake cursor harness that holds the home lock.
# Clear PI_CODING_AGENT so a Pi host session running this suite cannot make the
# Cursor park stand down before the fixture under test is exercised.
run_park() {  # <dir> [loop_count] [loop_ceiling]
  local dir=$1 loop=${2:-0} ceiling=${3:-} payload
  payload=$(printf '{"session_id":"sess-cursor","generation_id":"gen-%s","loop_count":%s,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}' "$loop" "$loop")
  if [ -n "$ceiling" ]; then
    printf '%s' "$payload" | env -u PI_CODING_AGENT FM_HOME="$dir" FM_CURSOR_PARK_POLL=1 \
      FM_CURSOR_TURNEND_LOOP_CEILING="$ceiling" "$FAKE_CURSOR" -c "$PARK_CHILD" 2>/dev/null
  else
    printf '%s' "$payload" | env -u PI_CODING_AGENT FM_HOME="$dir" FM_CURSOR_PARK_POLL=1 \
      "$FAKE_CURSOR" -c "$PARK_CHILD" 2>/dev/null
  fi
}

run_session() {  # <dir> <event> <source> [session-id]
  local dir=$1 event=$2 source=$3 session_id=${4:-sess-cursor} payload
  payload=$(printf '{"hook_event_name":"%s","session_id":"%s","cursor_version":"x"}' "$event" "$session_id")
  printf '%s' "$payload" | FM_HOME="$dir" FM_SESSION_SOURCE="$source" "$FAKE_CURSOR" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-sessionstart-cursor.sh" --source "$FM_SESSION_SOURCE"
  ' 2>/dev/null
}

followup_of() {  # <json>
  printf '%s' "$1" | jq -r '.followup_message // empty' 2>/dev/null
}

kind_of_followup() {  # <json> -> the operational kind
  local body
  body=$(followup_of "$1")
  [ -n "$body" ] || return 1
  printf '%s' "$body" | "$ROOT/bin/fm-operational-input.sh" kind
}

# --- HOST GUARD --------------------------------------------------------------

test_turnend_guard_stands_down_on_cursor_payload() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-turnend")
  : > "$dir/state/task1.meta"
  out=$(printf '%s' "$CURSOR_PAYLOAD" | bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "a Cursor-delivered Stop payload must not block through the Claude-settings duplicate"
  [ -z "$out" ] || fail "duplicate entry produced output: $out"
  out=$(printf '%s' "$CURSOR_PAYLOAD" | bash "$dir/bin/fm-turnend-guard.sh" --cursor 2>&1); status=$?
  expect_code 2 "$status" "--cursor must let Cursor's own adapter reach the shared block decision"
  case "$out" in *'TURN WOULD END BLIND'*) ;; *) fail "expected the shared banner, got: $out" ;; esac
  pass "fm-turnend-guard: Cursor payload is inert without --cursor and blocks with it"
}

test_turnend_guard_still_blocks_for_claude_payload() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/host-claude")
  : > "$dir/state/task1.meta"
  printf '%s' "$CLAUDE_STOP_PAYLOAD" | bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "the host guard must not disturb a genuine Claude Stop payload"
  pass "fm-turnend-guard: a non-Cursor payload keeps blocking"
}

test_autoarm_stands_down_on_cursor_payload() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/host-autoarm")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  printf '%s' "$CURSOR_PAYLOAD" | FM_HOME="$dir" "$FAKE_CURSOR" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
    ' >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "the Claude auto-arm must stay inert under Cursor"
  [ ! -e "$dir/state/arm-ran" ] || fail "the Claude auto-arm armed under a Cursor payload; on Cursor it would run synchronously and hold the turn open for its multi-hour timeout"
  pass "fm-claude-stop-autoarm: inert on a Cursor-delivered payload"
}

test_sessionstart_run_stands_down_on_cursor_payload() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/host-sessionstart")
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/digest-ran"
printf 'DIGEST BODY\n'
SH
  chmod +x "$dir/bin/fm-session-start.sh"
  out=$(printf '%s' "$CURSOR_PAYLOAD" | FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-run.sh" 2>&1)
  [ -z "$out" ] || fail "the run wrapper emitted a digest for the Cursor duplicate: $out"
  [ ! -e "$dir/state/digest-ran" ] || fail "the run wrapper took the helm twice under Cursor"
  out=$(printf '{"source":"startup","session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-run.sh" 2>&1)
  case "$out" in *'DIGEST BODY'*) ;; *) fail "a Claude-shaped payload must still run the digest, got: $out" ;; esac
  pass "fm-sessionstart-run: inert on a Cursor payload, unchanged otherwise"
}

test_pretool_guards_deduplicate_and_render_cursor_deny() {
  local dir payload out status decision
  dir=$(make_primary_dir "$TMP_ROOT/host-pretool")
  payload='{"tool_name":"Shell","tool_input":{"command":"bin/fm-watch-arm.sh &"},"cursor_version":"2026.08.11-e8db854"}'
  out=$(printf '%s' "$payload" | bash "$dir/bin/fm-arm-pretool-check.sh" 2>&1); status=$?
  expect_code 0 "$status" "the Claude-settings duplicate must allow under Cursor"
  [ -z "$out" ] || fail "duplicate pretool entry produced output: $out"

  out=$(printf '%s' "$payload" | bash "$dir/bin/fm-arm-pretool-check.sh" --cursor 2>/dev/null); status=$?
  expect_code 0 "$status" "Cursor reads the decision object, so the deny path exits 0"
  decision=$(printf '%s' "$out" | jq -r '.permission // empty' 2>/dev/null)
  [ "$decision" = deny ] || fail "expected a Cursor deny object on stdout, got: $out"
  printf '%s' "$out" | jq -e '.user_message | type == "string" and length > 0' >/dev/null 2>&1 \
    || fail "Cursor's deny object must carry a user_message reason, got: $out"
  pass "fm-arm-pretool-check: Cursor duplicate allows, --cursor denies in Cursor's own shape"
}

test_cd_guard_renders_cursor_deny() {
  local dir payload out decision
  dir=$(make_primary_dir "$TMP_ROOT/host-cd")
  payload='{"tool_name":"Shell","tool_input":{"command":"cd projects/example"},"cursor_version":"2026.08.11-e8db854"}'
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" --cursor 2>/dev/null)
  decision=$(printf '%s' "$out" | jq -r '.permission // empty' 2>/dev/null)
  [ "$decision" = deny ] || fail "expected a Cursor deny object from the cd guard, got: $out"
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" 2>&1)
  [ -z "$out" ] || fail "the cd guard's Claude-settings duplicate produced output under Cursor: $out"
  pass "fm-cd-pretool-check: Cursor duplicate allows, --cursor denies in Cursor's own shape"
}

# --- PARK --------------------------------------------------------------------

test_park_silent_when_nothing_in_flight() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-idle")
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  [ -z "$out" ] || fail "the park emitted a follow-up with nothing in flight: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed with nothing to supervise"
  pass "cursor park: silent no-op when no supervision is needed"
}

test_park_delivers_actionable_wake_as_followup() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-wake")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  [ -e "$dir/state/arm-ran" ] || fail "the park did not run the arm"
  [ "$(kind_of_followup "$out")" = watcher ] \
    || fail "an actionable close must arrive as a watcher-kind follow-up, got: $out"
  body=$(followup_of "$out")
  case "$body" in *'stale: fixture-win needs a look'*) ;; *) fail "the wake reason was not carried into the follow-up: $body" ;; esac
  case "$body" in *'fm-wake-drain.sh'*) ;; *) fail "the follow-up must tell the session to drain first: $body" ;; esac
  pass "cursor park: an actionable close is delivered as one watcher-kind follow-up"
}

test_park_never_exits_two() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/park-exit")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  run_park "$dir" >/dev/null; status=$?
  expect_code 0 "$status" "exit 2 is a silent no-op on Cursor's stop step, so the adapter must never use it"
  pass "cursor park: always exits 0, even when supervision is genuinely down"
}

test_park_repair_nag_is_bounded() {
  local dir out i kinds=0
  dir=$(make_primary_dir "$TMP_ROOT/park-nag")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  for i in 1 2 3; do
    out=$(run_park "$dir")
    [ "$(kind_of_followup "$out")" = turn-end-guard ] \
      || fail "nag $i should be a turn-end-guard follow-up, got: $out"
    kinds=$((kinds + 1))
  done
  out=$(run_park "$dir")
  [ -z "$out" ] || fail "the repair nag must stop after its budget, got a 4th: $out"
  [ "$kinds" -eq 3 ] || fail "expected exactly 3 bounded nags, saw $kinds"
  pass "cursor park: the repair nag is bounded and then goes quiet"
}

test_park_repair_nag_requires_a_persisted_budget() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nag-write-failure")
  : > "$dir/state/task1.meta"
  mkdir "$dir/state/.turnend-cursor-blocks"
  write_arm_fixture "$dir" failed
  out=$(run_park "$dir")
  [ -z "$out" ] || fail "a repair nag without a persisted budget increment must fail open: $out"
  [ -z "$(find "$dir/state/.turnend-cursor-blocks" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || fail "the failed budget commit left partial state"
  pass "cursor park: a repair nag is emitted only after its budget persists"
}

test_park_nag_budget_resets_after_a_real_wake() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nag-reset")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  run_park "$dir" >/dev/null
  run_park "$dir" >/dev/null
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  [ "$(kind_of_followup "$out")" = watcher ] || fail "expected a real wake, got: $out"
  write_arm_fixture "$dir" failed
  out=$(run_park "$dir")
  [ "$(kind_of_followup "$out")" = turn-end-guard ] \
    || fail "a productive wake must reset the nag budget, got: $out"
  pass "cursor park: a delivered wake resets the bounded repair budget"
}

test_park_loop_ceiling_warns_once_then_goes_quiet() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-ceiling")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir" 5 5)
  body=$(followup_of "$out")
  case "$body" in *'CEILING REACHED'*) ;; *) fail "at the ceiling the session must be told once, got: $out" ;; esac
  [ ! -e "$dir/state/arm-ran" ] || fail "the park must not arm at the loop ceiling"
  out=$(run_park "$dir" 6 5)
  [ -z "$out" ] || fail "above the ceiling the adapter must be silent, got: $out"
  pass "cursor park: the loop_count ceiling warns exactly once, then stops the loop"
}



test_park_stands_down_when_superseded() {
  local dir first_out first_pid marker
  dir=$(make_primary_dir "$TMP_ROOT/park-supersede")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  marker="$dir/state/first-park-out"
  ( run_park "$dir" > "$marker" 2>/dev/null ) &
  first_pid=$!
  local waited=0
  while [ ! -s "$dir/state/.cursor-park-owner" ] || [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.2
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "the first park never claimed ownership"
  done
  : > "$dir/state/arm-fast"
  run_park "$dir" >/dev/null 2>&1
  wait "$first_pid" 2>/dev/null || true
  first_out=$(cat "$marker" 2>/dev/null || true)
  [ -z "$first_out" ] || fail "the older park delivered after the newer stop claimed the baton: $first_out"
  pass "cursor park: an older park stands down after a newer stop claim"
}

test_park_serializes_supersession_with_followup_commit() {
  local dir first_pid first_out second_out waited budget_count
  dir=$(make_primary_dir "$TMP_ROOT/park-commit-race")
  : > "$dir/state/task1.meta"
  printf 'session=sess-cursor\ncount=1\n' > "$dir/state/.turnend-cursor-blocks"
  write_arm_fixture "$dir" actionable
  cat >> "$dir/bin/fm-operational-input.sh" <<'SH'
fm_operational_input_encode() {
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && fm_operational_kind_is_current "$kind" && [ -n "$body" ] || return 2
  if ( set -C; : > "$FM_HOME/state/commit-entered" ) 2>/dev/null; then
    while [ ! -e "$FM_HOME/state/commit-release" ]; do sleep 0.05; done
  fi
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}
SH
  ( run_park "$dir" > "$dir/state/first-out" ) &
  first_pid=$!
  waited=0
  while [ ! -e "$dir/state/commit-entered" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the first park never entered follow-up preparation"
  done
  write_arm_fixture "$dir" failed
  second_out=$(run_park "$dir")
  : > "$dir/state/commit-release"
  wait "$first_pid" 2>/dev/null || true
  first_out=$(cat "$dir/state/first-out" 2>/dev/null || true)
  [ -z "$first_out" ] || fail "the older park emitted after a newer stop arrived: $first_out"
  [ "$(kind_of_followup "$second_out")" = turn-end-guard ] \
    || fail "the newest park did not own the follow-up: $second_out"
  budget_count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-cursor-blocks" 2>/dev/null || true)
  [ "$budget_count" = 2 ] \
    || fail "the superseded actionable park reset shared nag state: $budget_count"
  pass "cursor park: the newest stop exclusively owns a concurrent commit"
}

test_superseded_park_does_not_consume_nag_budget() {
  local dir first_pid second_out waited budget_count
  dir=$(make_primary_dir "$TMP_ROOT/park-nag-supersede")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
if ( set -C; : > "$FM_HOME/state/first-guard-entered" ) 2>/dev/null; then
  while [ ! -e "$FM_HOME/state/first-guard-release" ]; do sleep 0.05; done
fi
printf 'fixture supervision failure\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  ( run_park "$dir" > "$dir/state/first-nag-out" ) &
  first_pid=$!
  waited=0
  while [ ! -e "$dir/state/first-guard-entered" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the first park never reached the guard decision"
  done
  second_out=$(run_park "$dir")
  : > "$dir/state/first-guard-release"
  wait "$first_pid" 2>/dev/null || true
  [ "$(kind_of_followup "$second_out")" = turn-end-guard ] \
    || fail "the current park did not deliver its repair nag: $second_out"
  [ ! -s "$dir/state/first-nag-out" ] \
    || fail "the superseded park delivered a stale repair nag"
  budget_count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-cursor-blocks" 2>/dev/null || true)
  [ "$budget_count" = 1 ] \
    || fail "the superseded park consumed the current park's nag budget: $budget_count"
  pass "cursor park: a superseded park cannot consume repair budget"
}

test_park_inert_when_afk() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-afk")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  [ -z "$out" ] || fail "away mode owns supervision; the park must not wake the primary: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed while the away daemon owns the watcher"
  pass "cursor park: inert while away mode is active"
}

test_park_inert_under_pi_coding_agent() {
  local dir out payload
  dir=$(make_primary_dir "$TMP_ROOT/park-pi-host")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  payload=$(printf '{"session_id":"sess-cursor","generation_id":"gen-0","loop_count":0,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}')
  # No Cursor identity markers: Pi host alone must stand the park down.
  out=$(printf '%s' "$payload" | env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_HOME="$dir" PI_CODING_AGENT=true FM_CURSOR_PARK_POLL=1 \
    "$FAKE_CURSOR" -c "$PARK_CHILD" 2>/dev/null)
  [ -z "$out" ] || fail "Pi-hosted Cursor SDK must not park or wake: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed under PI_CODING_AGENT=true"
  pass "cursor park: inert when PI_CODING_AGENT marks a Pi host session"
}

test_park_still_parks_with_pi_leak_and_cursor_identity() {
  local dir out body payload
  dir=$(make_primary_dir "$TMP_ROOT/park-pi-leak-cursor")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  payload=$(printf '{"session_id":"sess-cursor","generation_id":"gen-0","loop_count":0,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}')
  # Hand-started cursor-agent may inherit PI_CODING_AGENT; Cursor identity wins.
  out=$(printf '%s' "$payload" | env -u CURSOR_INVOKED_AS \
    FM_HOME="$dir" PI_CODING_AGENT=true CURSOR_AGENT=1 FM_CURSOR_PARK_POLL=1 \
    "$FAKE_CURSOR" -c "$PARK_CHILD" 2>/dev/null)
  [ -e "$dir/state/arm-ran" ] || fail "CURSOR_AGENT must still park despite PI_CODING_AGENT leak"
  [ "$(kind_of_followup "$out")" = watcher ] \
    || fail "CURSOR_AGENT park must deliver the wake despite PI leak: $out"
  body=$(followup_of "$out")
  case "$body" in *'stale: fixture-win needs a look'*) ;; *) fail "CURSOR_AGENT wake reason missing: $body" ;; esac
  rm -f "$dir/state/arm-ran"
  out=$(printf '%s' "$payload" | env -u CURSOR_AGENT \
    FM_HOME="$dir" PI_CODING_AGENT=true CURSOR_INVOKED_AS=cursor-agent FM_CURSOR_PARK_POLL=1 \
    "$FAKE_CURSOR" -c "$PARK_CHILD" 2>/dev/null)
  [ -e "$dir/state/arm-ran" ] || fail "CURSOR_INVOKED_AS must still park despite PI_CODING_AGENT leak"
  [ "$(kind_of_followup "$out")" = watcher ] \
    || fail "CURSOR_INVOKED_AS park must deliver the wake despite PI leak: $out"
  pass "cursor park: parks when PI_CODING_AGENT leaks alongside Cursor identity"
}

test_park_stands_down_when_away_mode_activates_before_commit() {
  local dir park_pid out waited budget_count
  dir=$(make_primary_dir "$TMP_ROOT/park-afk-transition")
  : > "$dir/state/task1.meta"
  printf 'session=sess-cursor\ncount=1\n' > "$dir/state/.turnend-cursor-blocks"
  write_arm_fixture "$dir" actionable
  cat >> "$dir/bin/fm-operational-input.sh" <<'SH'
fm_operational_input_encode() {
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && fm_operational_kind_is_current "$kind" && [ -n "$body" ] || return 2
  : > "$FM_HOME/state/afk-commit-entered"
  while [ ! -e "$FM_HOME/state/afk-commit-release" ]; do sleep 0.05; done
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}
SH
  ( run_park "$dir" > "$dir/state/afk-transition-out" ) &
  park_pid=$!
  waited=0
  while [ ! -e "$dir/state/afk-commit-entered" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the park never reached follow-up preparation"
  done
  : > "$dir/state/.afk"
  : > "$dir/state/afk-commit-release"
  wait "$park_pid" 2>/dev/null || true
  out=$(cat "$dir/state/afk-transition-out" 2>/dev/null || true)
  [ -z "$out" ] || fail "the park emitted after away mode activated: $out"
  budget_count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-cursor-blocks" 2>/dev/null || true)
  [ "$budget_count" = 1 ] || fail "the park reset nag state after away mode activated: $budget_count"
  pass "cursor park: an away-mode transition wins before follow-up commit"
}

test_park_inert_without_session_lock() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nolock")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s' "$CURSOR_PAYLOAD" | env -u PI_CODING_AGENT FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a session that does not hold the home lock must not arm or wake: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed without owning the session lock"
  pass "cursor park: inert when this session does not hold the home lock"
}

test_park_stands_down_after_session_takeover() {
  local dir park_pid out waited budget_count
  dir=$(make_primary_dir "$TMP_ROOT/park-session-takeover")
  : > "$dir/state/task1.meta"
  printf 'session=sess-cursor\ncount=1\n' > "$dir/state/.turnend-cursor-blocks"
  write_arm_fixture "$dir" switchable
  ( run_park "$dir" > "$dir/state/takeover-out" ) &
  park_pid=$!
  waited=0
  while [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the park never began polling before takeover"
  done
  printf '%s\n' "$$" > "$dir/state/.lock"
  wait "$park_pid" 2>/dev/null || true
  out=$(cat "$dir/state/takeover-out" 2>/dev/null || true)
  [ -z "$out" ] || fail "the replaced session emitted a follow-up after takeover: $out"
  budget_count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-cursor-blocks" 2>/dev/null || true)
  [ "$budget_count" = 1 ] || fail "the replaced session mutated nag state after takeover: $budget_count"
  pass "cursor park: session takeover stops polling without output or state mutation"
}

test_park_inert_in_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/park-base")
  child="$TMP_ROOT/park-child"
  fm_git_worktree "$base" "$child" fm/cursor-park-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  : > "$child/state/task1.meta"
  write_arm_fixture "$child" actionable
  out=$(run_park "$child")
  [ -z "$out" ] || fail "a crewmate worktree must stay outside primary scope: $out"
  pass "cursor park: inert inside a child crewmate worktree"
}

test_park_ignores_malformed_payload() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-malformed")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(printf 'not json at all' | env -u PI_CODING_AGENT FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a malformed payload must fail open, got: $out"
  out=$(printf '{"loop_count":"three","cursor_version":"x"}' | env -u PI_CODING_AGENT FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a non-numeric loop_count must fail open, got: $out"
  pass "cursor park: malformed payloads fail open without arming"
}

# --- SESSION -----------------------------------------------------------------

install_digest_fixture() {  # <dir>
  cat > "$1/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/digest-args"
printf 'FIRSTMATE DIGEST "quoted" line\nsecond line\n'
SH
  chmod +x "$1/bin/fm-session-start.sh"
}

test_sessionstart_emits_additional_context() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-start")
  install_digest_fixture "$dir"
  out=$(run_session "$dir" sessionStart startup)
  ctx=$(printf '%s' "$out" | jq -r '.additional_context // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST "quoted" line'*) ;; *) fail "the digest must reach model context verbatim, got: $out" ;; esac
  case "$ctx" in *'second line'*) ;; *) fail "the digest was truncated at the first line: $ctx" ;; esac
  grep -q -- '--source startup' "$dir/state/digest-args" \
    || fail "the adapter must supply --source itself; Cursor's payload has no source field"
  pass "fm-sessionstart-cursor: sessionStart injects context"
}

test_sessionstart_silent_in_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/session-base")
  child="$TMP_ROOT/session-child"
  fm_git_worktree "$base" "$child" fm/cursor-session-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  install_digest_fixture "$child"
  out=$(printf '{"hook_event_name":"sessionStart","cursor_version":"x"}' \
    | FM_HOME="$child" bash "$child/bin/fm-sessionstart-cursor.sh" --source startup 2>/dev/null)
  [ -z "$out" ] || fail "a child worktree must never take the helm: $out"
  pass "fm-sessionstart-cursor: silent inside a child crewmate worktree"
}

# --- registration ------------------------------------------------------------

test_tracked_registration_covers_the_primary_events() {
  local reg
  reg="$ROOT/.cursor/hooks.json"
  [ -f "$reg" ] || fail "firstmate must ship a tracked project-scope .cursor/hooks.json"
  jq -e '.hooks.stop and .hooks.sessionStart and .hooks.preToolUse' "$reg" >/dev/null 2>&1 \
    || fail "the registration must cover stop, sessionStart, and preToolUse"
  jq -e '.hooks | has("preCompact") | not' "$reg" >/dev/null 2>&1 \
    || fail "preCompact staging is deliberately deferred to a follow-up and must stay unregistered"
  jq -e '[.hooks.stop[] | select(.loop_limit != null and .loop_limit > 0)] | length == 1' "$reg" >/dev/null 2>&1 \
    || fail "the stop registration needs an explicit positive loop_limit: without it Cursor's default is unlimited"
  jq -e '[.hooks.sessionStart[]] | all(.timeout > 120)' "$reg" >/dev/null 2>&1 \
    || fail "the session-open timeout must sit above bin/fm-session-start.sh's own 120s budget"
  pass "cursor registration: covers every primary event with a bounded stop loop"
}

# The two bounds must nest, and the only honest way to prove it is to run the
# adapter at Cursor's own registered limit with its DEFAULT ceiling: firstmate's
# bound must already have stopped the loop by then, so Cursor's hard ceiling is
# never what silently ends supervision.
test_default_ceiling_bites_before_the_registered_loop_limit() {
  local dir limit out
  dir=$(make_primary_dir "$TMP_ROOT/park-nesting")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  limit=$(jq -r '.hooks.stop[0].loop_limit' "$ROOT/.cursor/hooks.json")
  case "$limit" in ''|*[!0-9]*) fail "the stop registration needs a numeric loop_limit, got: $limit" ;; esac
  out=$(run_park "$dir" "$((limit - 1))")
  [ -z "$out" ] || fail "at Cursor's own limit the adapter must already be quiet from its own bound, got: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the adapter armed past its own default ceiling"
  pass "cursor bounds nest: firstmate's default ceiling stops the loop before Cursor's loop_limit does"
}

test_turnend_guard_stands_down_on_cursor_payload
test_turnend_guard_still_blocks_for_claude_payload
test_autoarm_stands_down_on_cursor_payload
test_sessionstart_run_stands_down_on_cursor_payload
test_pretool_guards_deduplicate_and_render_cursor_deny
test_cd_guard_renders_cursor_deny
test_park_silent_when_nothing_in_flight
test_park_delivers_actionable_wake_as_followup
test_park_never_exits_two
test_park_repair_nag_is_bounded
test_park_repair_nag_requires_a_persisted_budget
test_park_nag_budget_resets_after_a_real_wake
test_park_loop_ceiling_warns_once_then_goes_quiet
test_park_stands_down_when_superseded
test_park_serializes_supersession_with_followup_commit
test_superseded_park_does_not_consume_nag_budget
test_park_inert_when_afk
test_park_inert_under_pi_coding_agent
test_park_still_parks_with_pi_leak_and_cursor_identity
test_park_stands_down_when_away_mode_activates_before_commit
test_park_inert_without_session_lock
test_park_stands_down_after_session_takeover
test_park_inert_in_child_worktree
test_park_ignores_malformed_payload
test_sessionstart_emits_additional_context
test_sessionstart_silent_in_child_worktree
test_tracked_registration_covers_the_primary_events
test_default_ceiling_bites_before_the_registered_loop_limit
