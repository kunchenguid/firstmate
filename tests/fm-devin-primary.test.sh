#!/usr/bin/env bash
# Behavior tests for Devin CLI as a firstmate PRIMARY
# (docs/turnend-guard.md, docs/sessionstart-nudge.md,
# docs/supervision-protocols/devin.md).
#
# Four layers, all hermetic over temp dirs with real processes and NO devin
# installed, so CI enforces them everywhere:
#   HOST GUARD  - bin/fm-hook-host-lib.sh, and each tracked Claude-shaped hook
#                 entrypoint standing down on a Devin-delivered payload, which
#                 is what keeps a Devin primary from running a covered event
#                 twice should a Claude import ever be enabled.
#   PARK        - bin/fm-turnend-guard-devin.sh, the Stop-hook park: its block
#                 channel, its prompt_id-keyed loop bound, its bounded repair
#                 nag, the own-pane captain stand-down, and its post-claim
#                 supersession contract.
#   SESSION     - bin/fm-sessionstart-devin.sh, which injects the digest at
#                 SessionStart.
#
# The park runs as a child of a fake harness (a compiled binary named devin)
# whose pid holds the fixture home's session lock, so the real Devin ancestry
# path in bin/fm-session-lock-lib.sh is exercised rather than stubbed. The own
# pane is replaced by FM_DEVIN_PANE_READ, a command the park polls instead of a
# backend capture, so the stand-down and unreadable-pane paths run without a
# multiplexer. tests/fm-devin-primary-live-e2e.test.sh is the opt-in guard
# against a real devin. Neither replaces the other.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-devin-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
# Use a real executable whose own canonical basename is devin: /proc resolves a
# bash symlink to bash on Linux, so the exact-name harness match in
# bin/fm-session-lock-lib.sh would correctly reject it as an impostor.
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake Devin process"
cat > "$TMP_ROOT/fake-devin.c" <<'C'
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
"$CC_BIN" -o "$FAKEBIN/devin" "$TMP_ROOT/fake-devin.c" \
  || fail "could not build the fake Devin process"
FAKE_DEVIN="$FAKEBIN/devin"

DEVIN_PAYLOAD='{"hook_event_name":"Stop","session_id":"sess-devin","prompt_id":"p-1","stop_hook_active":false}'
CLAUDE_STOP_PAYLOAD='{"session_id":"sess-claude","stop_hook_active":false,"transcript_path":"/t.jsonl"}'

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard-devin.sh fm-turnend-guard.sh fm-sessionstart-devin.sh \
           fm-sessionstart-run.sh fm-sessionstart-nudge.sh fm-arm-pretool-check.sh \
           fm-cd-pretool-check.sh fm-claude-stop-autoarm.sh fm-hook-host-lib.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh fm-path-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-supervisor-target-lib.sh fm-backend.sh \
           fm-gate-refuse-lib.sh; do
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

# A pane fixture standing in for this session's own pane. The park calls
# $FM_DEVIN_PANE_READ instead of a backend capture, so the queued-message and
# Escape stand-down markers - and the unreadable-pane repair path - run without
# a multiplexer.
write_pane_fixture() {  # <dir> <kind>
  local dir=$1 i
  mkdir -p "$dir/fixture"
  case "$2" in
    idle)
      printf '%s\n' '❭ Guide Devin while it works' > "$dir/fixture/pane.txt"
      ;;
    queued)
      {
        printf '%s\n' '── 1 queued ─────────────────────────── ↑ edit · ↵ send now ──'
        printf '%s\n' '○ PING-CAPTAIN reply with banana'
        printf '%s\n' '❭ Press Enter to send queued messages now'
      } > "$dir/fixture/pane.txt"
      ;;
    esc)
      printf '%s\n' '⠠ Typing · 10s (esc again to interrupt)' > "$dir/fixture/pane.txt"
      ;;
    poisoned)
      # Every marker string rendered in the transcript region - behind the
      # ` │ ` tool-output gutter and as bare text - while the bottom composer
      # row stays the ordinary working placeholder. None of these rows is a
      # real captain-activity marker, so the park must keep polling.
      {
        printf '%s\n' ' some earlier transcript output'
        printf '%s\n' ' │ output: Press Enter to send queued messages now is the hint'
        printf '%s\n' ' │   ── 1 queued ── renders like this in the docs'
        printf '%s\n' ' │ Typing · 3s (esc again to interrupt) is the esc marker row'
        printf '%s\n' ' output mentioned 3 queued ── and esc again to interrupt mid-line'
        printf '%s\n' 'Press Enter to send queued messages now quoted verbatim at column 0'
        printf '%s\n' '❭ Guide Devin while it works'
        printf '%s\n' 'SWE-2 Medium'
      } > "$dir/fixture/pane.txt"
      ;;
    high)
      # A real marker-shaped row, but far above the bottom composer region:
      # only the last rows of the capture are composer chrome, so a marker
      # that scrolled up is transcript, not captain activity.
      {
        printf '%s\n' '── 1 queued ─────────────────────────── ↑ edit · ↵ send now ──'
        printf '%s\n' '❭ Press Enter to send queued messages now'
        i=0
        while [ "$i" -lt 30 ]; do
          printf '%s\n' " transcript filler row $i"
          i=$((i + 1))
        done
        printf '%s\n' '❭ Guide Devin while it works'
        printf '%s\n' 'SWE-2 Medium'
      } > "$dir/fixture/pane.txt"
      ;;
    fail-later)
      printf '%s\n' '❭ Guide Devin while it works' > "$dir/fixture/pane.txt"
      ;;
  esac
  if [ "$2" = fail-later ]; then
    cat > "$dir/fixture/pane-read" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fixture/pane-fail" ] || exit 1
exec cat "$dir/fixture/pane.txt"
SH
  else
    cat > "$dir/fixture/pane-read" <<SH
#!/usr/bin/env bash
exec cat "$dir/fixture/pane.txt"
SH
  fi
  chmod +x "$dir/fixture/pane-read"
}

# The park's child body: claim the home lock as the fake devin process itself
# ($PPID inside the -c body), then run the adapter as its child, so the real
# Devin ancestry path decides lock ownership on every platform.
PARK_CHILD='
  printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-turnend-guard-devin.sh"
'

# Run the park as a child of the fake devin harness that holds the home lock.
run_park() {  # <dir> [prompt_id] [loop_ceiling] [one VAR=value env assignment]
  local dir=$1 prompt=${2:-p-1} ceiling=${3:-} extra=${4:-} payload
  payload=$(printf '{"hook_event_name":"Stop","session_id":"sess-devin","prompt_id":"%s","stop_hook_active":true}' "$prompt")
  if [ -n "$ceiling" ]; then
    printf '%s' "$payload" | env FM_HOME="$dir" FM_DEVIN_PARK_POLL=1 \
      FM_DEVIN_TURNEND_LOOP_CEILING="$ceiling" ${extra:+"$extra"} \
      "$FAKE_DEVIN" -c "$PARK_CHILD" 2>/dev/null
  else
    printf '%s' "$payload" | env FM_HOME="$dir" FM_DEVIN_PARK_POLL=1 ${extra:+"$extra"} \
      "$FAKE_DEVIN" -c "$PARK_CHILD" 2>/dev/null
  fi
}

decision_reason_of() {  # <json>
  printf '%s' "$1" | jq -r '.reason // empty' 2>/dev/null
}

kind_of_block() {  # <json> -> the operational kind
  local body
  body=$(decision_reason_of "$1")
  [ -n "$body" ] || return 1
  printf '%s' "$body" | "$ROOT/bin/fm-operational-input.sh" kind
}

# --- HOST GUARD --------------------------------------------------------------

test_turnend_guard_stands_down_on_devin_payload() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-turnend")
  : > "$dir/state/task1.meta"
  out=$(DEVIN_PROJECT_DIR="$dir" bash -c '
    printf "%s" "$0" | bash "$1/bin/fm-turnend-guard.sh"' "$DEVIN_PAYLOAD" "$dir" 2>&1); status=$?
  expect_code 0 "$status" "a Devin-delivered Stop payload must not block through the Claude-compatibility duplicate"
  [ -z "$out" ] || fail "duplicate entry produced output: $out"
  out=$(DEVIN_PROJECT_DIR="$dir" bash -c '
    printf "%s" "$0" | bash "$1/bin/fm-turnend-guard.sh" --devin' "$DEVIN_PAYLOAD" "$dir" 2>&1); status=$?
  expect_code 2 "$status" "--devin must let Devin's own adapter reach the shared block decision"
  case "$out" in *'TURN WOULD END BLIND'*) ;; *) fail "expected the shared banner, got: $out" ;; esac
  pass "fm-turnend-guard: Devin payload is inert without --devin and blocks with it"
}

test_turnend_guard_still_blocks_for_claude_payload() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/host-claude")
  : > "$dir/state/task1.meta"
  printf '%s' "$CLAUDE_STOP_PAYLOAD" | env -u DEVIN_PROJECT_DIR bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a genuine Claude payload must keep blocking under an empty DEVIN_PROJECT_DIR"
  printf '%s' "$CLAUDE_STOP_PAYLOAD" | DEVIN_PROJECT_DIR="$dir" bash "$dir/bin/fm-turnend-guard.sh" >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a Claude payload's own transcript_path defeats the Devin arm even with DEVIN_PROJECT_DIR set"
  pass "fm-turnend-guard: transcript_path keeps a genuine Claude payload blocking"
}

test_autoarm_stands_down_on_devin_payload() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/host-autoarm")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  printf '%s' "$DEVIN_PAYLOAD" | DEVIN_PROJECT_DIR="$dir" FM_HOME="$dir" "$FAKE_DEVIN" -c '
      printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"
      exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
    ' >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "the Claude auto-arm must stay inert under Devin"
  [ ! -e "$dir/state/arm-ran" ] || fail "the Claude auto-arm armed under a Devin payload; on Devin asyncRewake is ignored so it would park the turn synchronously for its multi-hour timeout"
  pass "fm-claude-stop-autoarm: inert on a Devin-delivered payload"
}

test_sessionstart_run_stands_down_on_devin_payload() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/host-sessionstart")
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/digest-ran"
printf 'DIGEST BODY\n'
SH
  chmod +x "$dir/bin/fm-session-start.sh"
  out=$(printf '%s' "$DEVIN_PAYLOAD" | DEVIN_PROJECT_DIR="$dir" FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-run.sh" 2>&1)
  [ -z "$out" ] || fail "the run wrapper emitted a digest for the Devin duplicate: $out"
  [ ! -e "$dir/state/digest-ran" ] || fail "the run wrapper took the helm twice under Devin"
  out=$(printf '%s' "$CLAUDE_STOP_PAYLOAD" | DEVIN_PROJECT_DIR="$dir" FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-run.sh" 2>&1)
  [ -e "$dir/state/digest-ran" ] || fail "a Claude payload with transcript_path must still run the digest under DEVIN_PROJECT_DIR (out=$out; state=$(ls "$dir/state" 2>&1))"
  pass "fm-sessionstart-run: inert on a Devin payload, unchanged otherwise"
}

test_pretool_guards_deduplicate_and_render_devin_block() {
  local dir payload out status
  dir=$(make_primary_dir "$TMP_ROOT/host-pretool")
  payload='{"tool_name":"exec","tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
  out=$(printf '%s' "$payload" | DEVIN_PROJECT_DIR="$dir" bash "$dir/bin/fm-arm-pretool-check.sh" 2>&1); status=$?
  expect_code 0 "$status" "the Claude-compatibility duplicate must allow under Devin"
  [ -z "$out" ] || fail "duplicate pretool entry produced output: $out"

  out=$(printf '%s' "$payload" | DEVIN_PROJECT_DIR="$dir" bash "$dir/bin/fm-arm-pretool-check.sh" --devin 2>/dev/null); status=$?
  expect_code 0 "$status" "Devin reads the block decision object, so the deny path exits 0"
  jq -e '.decision == "block" and (.reason | type == "string" and length > 0)' <<<"$out" >/dev/null 2>&1 \
    || fail "expected a Devin block decision on stdout, got: $out"
  pass "fm-arm-pretool-check: Devin duplicate allows, --devin blocks in Devin's own shape"
}

test_cd_guard_renders_devin_block() {
  local dir payload out
  dir=$(make_primary_dir "$TMP_ROOT/host-cd")
  payload='{"tool_name":"exec","tool_input":{"command":"cd projects/example"}}'
  out=$(printf '%s' "$payload" | DEVIN_PROJECT_DIR="$dir" FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" --devin 2>/dev/null)
  jq -e '.decision == "block" and (.reason | type == "string" and length > 0)' <<<"$out" >/dev/null 2>&1 \
    || fail "expected a Devin block decision from the cd guard, got: $out"
  out=$(printf '%s' "$payload" | DEVIN_PROJECT_DIR="$dir" FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" 2>&1)
  [ -z "$out" ] || fail "the cd guard's Claude-compatibility duplicate produced output under Devin: $out"
  pass "fm-cd-pretool-check: Devin duplicate allows, --devin blocks in Devin's own shape"
}

# --- PARK --------------------------------------------------------------------

test_park_silent_when_nothing_in_flight() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-idle")
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "the park emitted a block with nothing in flight: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed with nothing to supervise"
  pass "devin park: silent no-op when no supervision is needed"
}

test_park_delivers_actionable_wake_as_block_decision() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-wake")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -e "$dir/state/arm-ran" ] || fail "the park did not run the arm"
  jq -e '.decision == "block"' <<<"$out" >/dev/null 2>&1 \
    || fail "an actionable close must arrive as a block decision, got: $out"
  [ "$(kind_of_block "$out")" = watcher ] \
    || fail "an actionable close must carry the watcher operational kind, got: $out"
  body=$(decision_reason_of "$out")
  case "$body" in *'stale: fixture-win needs a look'*) ;; *) fail "the wake reason was not carried into the block reason: $body" ;; esac
  case "$body" in *'fm-wake-drain.sh'*) ;; *) fail "the reason must tell the session to drain first: $body" ;; esac
  pass "devin park: an actionable close is delivered as one watcher-kind block decision"
}

test_park_never_exits_nonzero() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/park-exit")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  write_pane_fixture "$dir" idle
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" >/dev/null; status=$?
  expect_code 0 "$status" "the adapter must always exit 0; its only channel is the stdout decision object"
  pass "devin park: always exits 0, even when supervision is genuinely down"
}

test_park_loop_counter_increments_and_resets_on_new_prompt() {
  local dir out count
  dir=$(make_primary_dir "$TMP_ROOT/park-loops")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" >/dev/null
  count=$(sed -n '3s/^count=//p' "$dir/state/.devin-park-loops" 2>/dev/null)
  [ "$count" = 1 ] || fail "the first block must record count=1, got: $count"
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" >/dev/null
  count=$(sed -n '3s/^count=//p' "$dir/state/.devin-park-loops" 2>/dev/null)
  [ "$count" = 2 ] || fail "the second block on the same prompt must record count=2, got: $count"
  out=$(run_park "$dir" p-2 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  count=$(sed -n '3s/^count=//p' "$dir/state/.devin-park-loops" 2>/dev/null)
  [ "$count" = 1 ] || fail "a new prompt_id must reset the loop counter, got: $count"
  [ "$(kind_of_block "$out")" = watcher ] || fail "the reset prompt must still deliver its wake: $out"
  pass "devin park: the prompt_id-keyed loop counter increments per block and resets on a new prompt"
}

test_park_loop_ceiling_warns_once_then_goes_quiet() {
  local dir out body count
  dir=$(make_primary_dir "$TMP_ROOT/park-ceiling")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  printf 'session=sess-devin\nprompt=p-1\ncount=4\n' > "$dir/state/.devin-park-loops"
  out=$(run_park "$dir" p-1 5 "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  body=$(decision_reason_of "$out")
  case "$body" in *'CEILING REACHED'*) ;; *) fail "at the ceiling the session must be told once, got: $out" ;; esac
  printf 'session=sess-devin\nprompt=p-1\ncount=5\n' > "$dir/state/.devin-park-loops"
  out=$(run_park "$dir" p-1 5 "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "above the ceiling the adapter must be silent, got: $out"
  pass "devin park: the loop ceiling warns exactly once, then stops the loop"
}

test_park_loop_counter_fails_closed_when_state_is_a_directory() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-loops-directory")
  : > "$dir/state/task1.meta"
  mkdir "$dir/state/.devin-park-loops"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "an unpersistable loop counter must suppress the block, got: $out"
  [ -d "$dir/state/.devin-park-loops" ] || fail "the invalid loop-counter directory was replaced"
  pass "devin park: an unpersistable loop counter fails closed"
}

test_park_actionable_wake_does_not_count_when_budget_reset_fails() {
  local dir out count
  dir=$(make_primary_dir "$TMP_ROOT/park-budget-reset-fails")
  : > "$dir/state/task1.meta"
  mkdir "$dir/state/.turnend-devin-blocks"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "an actionable wake with an unresettable budget must emit nothing, got: $out"
  count=$(sed -n '3s/^count=//p' "$dir/state/.devin-park-loops" 2>/dev/null)
  [ -z "$count" ] || fail "a suppressed actionable wake must not consume a loop count, got: $count"
  pass "devin park: a failed budget reset leaves the loop count unchanged"
}

test_park_repair_does_not_count_when_budget_write_fails() {
  local dir out count
  dir=$(make_primary_dir "$TMP_ROOT/park-budget-write-fails")
  : > "$dir/state/task1.meta"
  mkdir "$dir/state/.turnend-devin-blocks"
  write_arm_fixture "$dir" failed
  write_pane_fixture "$dir" idle
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "a repair with an unwritable budget must emit nothing, got: $out"
  count=$(sed -n '3s/^count=//p' "$dir/state/.devin-park-loops" 2>/dev/null)
  [ -z "$count" ] || fail "a suppressed repair must not consume a loop count, got: $count"
  pass "devin park: a failed budget write leaves the loop count unchanged"
}

# Keep polling idle until the arm is gone, then expose the final-pane state.
# This isolates the post-arm emission window from the ordinary polling path.
test_park_checks_pane_after_arm_close() {
  local dir out arm_kind pane_kind
  for arm_kind in actionable failed; do
    for pane_kind in queued esc unreadable; do
      dir=$(make_primary_dir "$TMP_ROOT/park-final-$arm_kind-$pane_kind")
      : > "$dir/state/task1.meta"
      write_arm_fixture "$dir" "$arm_kind"
      write_pane_fixture "$dir" "$pane_kind"
      cat > "$dir/fixture/pane-read" <<'SH'
#!/usr/bin/env bash
pid=$(tail -1 "$FM_HOME/state/arm-ran" 2>/dev/null)
if [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then
  printf '%s\n' '❭ Guide Devin while it works'
else
  : > "$FM_HOME/state/final-pane-read"
  cat "$FM_HOME/fixture/pane.txt"
fi
SH
      out=$(FM_DEVIN_PARK_ATTEMPTS=1 run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
      [ -z "$out" ] || fail "$arm_kind close must stand down for final $pane_kind pane, got: $out"
      [ -e "$dir/state/final-pane-read" ] || fail "the pane was never checked after the arm closed"
      [ ! -e "$dir/state/.devin-park-loops" ] || fail "final pane stand-down consumed a loop count"
      [ ! -e "$dir/state/.turnend-devin-blocks" ] || fail "final pane stand-down consumed a repair nag"
    done
  done
  pass "devin park: final queued, Escape, and unreadable panes suppress both wake and repair blocks"
}

test_park_refuses_arm_without_output_capture() {
  local dir out real_mktemp i
  dir=$(make_primary_dir "$TMP_ROOT/park-no-capture")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  real_mktemp=$(command -v mktemp)
  cat > "$dir/fixture/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in *'.devin-park-output.'*) exit 1 ;; esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$dir/fixture/mktemp"
  for i in 1 2 3 4; do
    out=$(PATH="$dir/fixture:$PATH" run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
    [ ! -e "$dir/state/arm-ran" ] || fail "the watcher arm ran without an output capture channel"
    if [ "$i" -le 3 ]; then
      [ "$(kind_of_block "$out")" = turn-end-guard ] || fail "capture failure must issue a bounded repair notice: $out"
      case "$(decision_reason_of "$out")" in *'capture'*) ;; *) fail "repair must identify the missing capture channel: $out" ;; esac
    else
      [ -z "$out" ] || fail "capture failure exceeded the repair budget: $out"
    fi
  done
  pass "devin park: capture failure never arms, including after repair budget exhaustion"
}

test_park_stands_down_on_queued_captain_input() {
  local dir park_pid out waited
  dir=$(make_primary_dir "$TMP_ROOT/park-queued")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  write_pane_fixture "$dir" idle
  ( run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" > "$dir/state/park-out" ) &
  park_pid=$!
  waited=0
  while [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the park never began polling its pane"
  done
  write_pane_fixture "$dir" queued
  wait "$park_pid" 2>/dev/null || true
  out=$(cat "$dir/state/park-out" 2>/dev/null || true)
  [ -z "$out" ] || fail "the park must stand down silently when captain input is queued, got: $out"
  pass "devin park: a queued captain message ends the park without a block"
}

test_park_stands_down_on_escape_marker() {
  local dir park_pid out waited
  dir=$(make_primary_dir "$TMP_ROOT/park-esc")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  write_pane_fixture "$dir" idle
  ( run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" > "$dir/state/park-out" ) &
  park_pid=$!
  waited=0
  while [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the park never began polling its pane"
  done
  write_pane_fixture "$dir" esc
  wait "$park_pid" 2>/dev/null || true
  out=$(cat "$dir/state/park-out" 2>/dev/null || true)
  [ -z "$out" ] || fail "the park must stand down silently on the Escape marker, got: $out"
  pass "devin park: an esc-again marker ends the park without a block"
}

test_park_stands_down_when_pane_read_fails_mid_park() {
  local dir park_pid out waited
  dir=$(make_primary_dir "$TMP_ROOT/park-pane-fails")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  write_pane_fixture "$dir" fail-later
  ( run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" > "$dir/state/park-out" ) &
  park_pid=$!
  waited=0
  while [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the park never began polling its pane"
  done
  : > "$dir/fixture/pane-fail"
  wait "$park_pid" 2>/dev/null || true
  out=$(cat "$dir/state/park-out" 2>/dev/null || true)
  [ -z "$out" ] || fail "the park must stand down silently when its pane becomes unreadable, got: $out"
  pass "devin park: a pane read failure during polling ends the park silently"
}

test_park_ignores_transcript_marker_text() {
  local dir park_pid out waited kind
  for kind in poisoned high; do
    dir=$(make_primary_dir "$TMP_ROOT/park-$kind")
    : > "$dir/state/task1.meta"
    write_arm_fixture "$dir" switchable
    write_pane_fixture "$dir" "$kind"
    ( run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" > "$dir/state/park-out" ) &
    park_pid=$!
    waited=0
    while [ ! -e "$dir/state/arm-ran" ]; do
      sleep 0.1
      waited=$((waited + 1))
      [ "$waited" -lt 200 ] || fail "the park never began polling its pane"
    done
    # Several poll ticks with every marker string visible only in the
    # transcript region: a whole-screen substring match would stand down
    # instantly; the bottom-region anchored verdict must keep polling.
    sleep 3
    if ! kill -0 "$park_pid" 2>/dev/null; then
      out=$(cat "$dir/state/park-out" 2>/dev/null || true)
      fail "marker text in the transcript region ($kind) falsely stood the park down; out=$out"
    fi
    # Prove the same pane read still ends the park on a real marker.
    write_pane_fixture "$dir" queued
    wait "$park_pid" 2>/dev/null || true
    out=$(cat "$dir/state/park-out" 2>/dev/null || true)
    [ -z "$out" ] || fail "the park must stand down silently once a real marker appears ($kind), got: $out"
  done
  pass "devin park: marker strings in the transcript region or above the composer region do not stand the park down"
}

test_park_refuses_to_park_blind() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-blind")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  # A failing pane read counts as unreadable: parking blind would lock the
  # captain out of the queued-input stand-down for the whole hook timeout.
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=false")
  [ "$(kind_of_block "$out")" = turn-end-guard ] \
    || fail "an unreadable pane must produce one bounded repair follow-up, got: $out"
  body=$(decision_reason_of "$out")
  case "$body" in *'tmux or herdr pane'*|*'tmux or Herdr pane'*) ;; *) fail "the repair reason must name the pane requirement: $body" ;; esac
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed a watcher it could not watch over"
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=false" >/dev/null
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=false" >/dev/null
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=false")
  [ -z "$out" ] || fail "the unreadable-pane nag must be bounded like every repair nag, got a 4th: $out"
  pass "devin park: an unreadable pane yields one bounded repair follow-up, never a blind park"
}

test_park_repair_nag_is_bounded() {
  local dir out i kinds=0
  dir=$(make_primary_dir "$TMP_ROOT/park-nag")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  write_pane_fixture "$dir" idle
  for i in 1 2 3; do
    out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
    [ "$(kind_of_block "$out")" = turn-end-guard ] \
      || fail "nag $i should be a turn-end-guard block, got: $out"
    kinds=$((kinds + 1))
  done
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "the repair nag must stop after its budget, got a 4th: $out"
  [ "$kinds" -eq 3 ] || fail "expected exactly 3 bounded nags, saw $kinds"
  pass "devin park: the repair nag is bounded and then goes quiet"
}

test_park_nag_budget_resets_after_a_real_wake() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nag-reset")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  write_pane_fixture "$dir" idle
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" >/dev/null
  run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" >/dev/null
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ "$(kind_of_block "$out")" = watcher ] || fail "expected a real wake, got: $out"
  write_arm_fixture "$dir" failed
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ "$(kind_of_block "$out")" = turn-end-guard ] \
    || fail "a productive wake must reset the nag budget, got: $out"
  pass "devin park: a delivered wake resets the bounded repair budget"
}

test_park_stands_down_when_superseded() {
  local dir first_pid first_out waited count
  dir=$(make_primary_dir "$TMP_ROOT/park-supersede")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  write_pane_fixture "$dir" idle
  ( run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read" > "$dir/state/first-park-out" ) &
  first_pid=$!
  waited=0
  while [ ! -s "$dir/state/.devin-park-owner" ] || [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the first park never claimed ownership"
  done
  : > "$dir/state/arm-fast"
  run_park "$dir" >/dev/null 2>&1
  wait "$first_pid" 2>/dev/null || true
  first_out=$(cat "$dir/state/first-park-out" 2>/dev/null || true)
  [ -z "$first_out" ] || fail "the older park delivered after the newer stop claimed the baton: $first_out"
  count=$(sed -n '3s/^count=//p' "$dir/state/.devin-park-loops" 2>/dev/null)
  [ "$count" = 1 ] || fail "the superseded park must not consume a loop count, got: $count"
  pass "devin park: an older park stands down after a newer stop claim"
}

test_park_inert_when_afk() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-afk")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(run_park "$dir" p-1 '' "FM_DEVIN_PANE_READ=$dir/fixture/pane-read")
  [ -z "$out" ] || fail "away mode owns supervision; the park must not wake the primary: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed while the away daemon owns the watcher"
  pass "devin park: inert while away mode is active"
}

test_park_inert_without_session_lock() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nolock")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(printf '%s' "$DEVIN_PAYLOAD" | FM_HOME="$dir" \
    FM_DEVIN_PANE_READ=$dir/fixture/pane-read \
    bash "$dir/bin/fm-turnend-guard-devin.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a session that does not hold the home lock must not arm or wake: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed without owning the session lock"
  pass "devin park: inert when this session does not hold the home lock"
}

test_park_inert_in_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/park-base")
  child="$TMP_ROOT/park-child"
  fm_git_worktree "$base" "$child" fm/devin-park-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  : > "$child/state/task1.meta"
  write_arm_fixture "$child" actionable
  write_pane_fixture "$child" idle
  out=$(run_park "$child" p-1 '' "FM_DEVIN_PANE_READ=$child/fixture/pane-read")
  [ -z "$out" ] || fail "a crewmate worktree must stay outside primary scope: $out"
  pass "devin park: inert inside a child crewmate worktree"
}

test_park_ignores_malformed_payload() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-malformed")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  write_pane_fixture "$dir" idle
  out=$(printf 'not json at all' | FM_HOME="$dir" \
    FM_DEVIN_PANE_READ=$dir/fixture/pane-read \
    bash "$dir/bin/fm-turnend-guard-devin.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a malformed payload must fail open, got: $out"
  pass "devin park: malformed payloads fail open without arming"
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

test_sessionstart_emits_hook_specific_context() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-start")
  install_digest_fixture "$dir"
  out=$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"sess-devin","source":"startup"}' \
    | FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-devin.sh" 2>/dev/null)
  jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$out" >/dev/null 2>&1 \
    || fail "the adapter must answer in Devin's hookSpecificOutput shape, got: $out"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST "quoted" line'*) ;; *) fail "the digest must reach model context verbatim, got: $out" ;; esac
  case "$ctx" in *'second line'*) ;; *) fail "the digest was truncated at the first line: $ctx" ;; esac
  grep -q -- '--source startup' "$dir/state/digest-args" \
    || fail "the adapter must forward the payload's source to the run wrapper"
  pass "fm-sessionstart-devin: SessionStart injects context in Devin's own shape"
}

test_sessionstart_silent_in_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/session-base")
  child="$TMP_ROOT/session-child"
  fm_git_worktree "$base" "$child" fm/devin-session-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  install_digest_fixture "$child"
  out=$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"sess-devin","source":"startup"}' \
    | FM_HOME="$child" bash "$child/bin/fm-sessionstart-devin.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a child worktree must never take the helm: $out"
  pass "fm-sessionstart-devin: silent inside a child crewmate worktree"
}

# --- registration ------------------------------------------------------------

test_tracked_registration_covers_the_primary_events() {
  local reg
  reg="$ROOT/.devin/hooks.v1.json"
  [ -f "$reg" ] || fail "firstmate must ship a tracked project-scope .devin/hooks.v1.json"
  jq -e '.SessionStart and .Stop and .PreToolUse' "$reg" >/dev/null 2>&1 \
    || fail "the registration must cover SessionStart, Stop, and PreToolUse"
  jq -e '[.Stop[].hooks[].timeout] | all(. >= 28800)' "$reg" >/dev/null 2>&1 \
    || fail "the Stop park needs a hook timeout far above Devin's ~60s default"
  jq -e '[.SessionStart[].hooks[].timeout] | all(. > 120)' "$reg" >/dev/null 2>&1 \
    || fail "the session-open timeout must sit above bin/fm-session-start.sh's own 120s budget"
  jq -e 'has("UserPromptSubmit") | not' "$reg" >/dev/null 2>&1 \
    || fail "Devin registers no UserPromptSubmit hook; the supervision host is not in scope for it"
  jq -e '.read_config_from.claude == false' "$ROOT/.devin/config.json" >/dev/null 2>&1 \
    || fail "tracked .devin/config.json must disable the Claude import so .claude/settings.json hooks cannot double-fire"
  pass "devin registration: covers every primary event with a long Stop timeout and Claude import off"
}

test_turnend_guard_stands_down_on_devin_payload
test_turnend_guard_still_blocks_for_claude_payload
test_autoarm_stands_down_on_devin_payload
test_sessionstart_run_stands_down_on_devin_payload
test_pretool_guards_deduplicate_and_render_devin_block
test_cd_guard_renders_devin_block
test_park_silent_when_nothing_in_flight
test_park_delivers_actionable_wake_as_block_decision
test_park_never_exits_nonzero
test_park_loop_counter_increments_and_resets_on_new_prompt
test_park_loop_ceiling_warns_once_then_goes_quiet
test_park_loop_counter_fails_closed_when_state_is_a_directory
test_park_actionable_wake_does_not_count_when_budget_reset_fails
test_park_repair_does_not_count_when_budget_write_fails
test_park_checks_pane_after_arm_close
test_park_refuses_arm_without_output_capture
test_park_stands_down_on_queued_captain_input
test_park_stands_down_on_escape_marker
test_park_stands_down_when_pane_read_fails_mid_park
test_park_ignores_transcript_marker_text
test_park_refuses_to_park_blind
test_park_repair_nag_is_bounded
test_park_nag_budget_resets_after_a_real_wake
test_park_stands_down_when_superseded
test_park_inert_when_afk
test_park_inert_without_session_lock
test_park_inert_in_child_worktree
test_park_ignores_malformed_payload
test_sessionstart_emits_hook_specific_context
test_sessionstart_silent_in_child_worktree
test_tracked_registration_covers_the_primary_events
