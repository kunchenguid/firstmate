#!/usr/bin/env bash
# tests/fm-anstoss.test.sh - the Anstoss-Automat (bin/fm-anstoss.sh):
# state-based detection of silently exited lanes and the two-step nudge
# ladder. Red-green matrix per detection case (standing / working-marker /
# CI-waiting children / declared machine wait / O-0018 API-error pane /
# terminal status), the full-capture rule (an API-error banner far above the
# prompt is found - the 2026-08-24 hand-sweep failure mode), endpoint-alive
# gating, secondmate exclusion, counter + stage-2 escalation, and the L34
# refuted-nudge interval extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANSTOSS="$ROOT/bin/fm-anstoss.sh"
TMP_ROOT=$(fm_test_tmproot fm-anstoss-tests)

# Build one hermetic case: state dir plus fake tmux/ps/tasks-axi/fm-send. The
# fakes read canned answers from files under the case dir so a test rewrites
# reality between sweeps without restarting anything: capture.txt (pane),
# fakebin/cputime.txt (CPU sample), fakebin/ps.table (process family),
# axi.states (backlog states), windows.txt (session inventory), sent.log.
make_anstoss_case() {  # <name> -> case-dir
  local name=$1
  local dir=$TMP_ROOT/$name
  local fakebin=$dir/fakebin
  mkdir -p "$dir/state" "$fakebin"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    cat "${FM_FAKE_TMUX_WINDOWS:-/dev/null}" 2>/dev/null
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_tty*) printf '%s\n' "${FM_FAKE_TMUX_TTY:-/dev/pts/42}"; exit 0 ;;
        *pane_current_command*)
          # Derived from the foreground row of ps.table so a shell-only pane
          # can never masquerade as an agent through this source.
          cmd=$(awk '$2 == $3 { print $4 }' "$(dirname "$0")/ps.table" 2>/dev/null | head -1)
          printf '%s\n' "${cmd:-${FM_FAKE_TMUX_CURRENT_COMMAND:-claude1}}"
          exit 0 ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    exit 0 ;;
esac
exit 1
SH

  # ps dispatches on the -o value; pane-scoped reads all come from the case's
  # own files next to this script (dirname "$0"), never from ambient reality.
  # `args=` resolves the requested pid from ps.table so an argv0 probe can never
  # resurrect a lane whose foreground table says shell-only.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
prev=""
pid=""
for a in "$@"; do
  case "$a" in
    time=*) cat "$here/cputime.txt" 2>/dev/null; exit 0 ;;
    -o) ;;
    -p) ;;
    args=)
      printf '/bin/%s\n' "$(awk -v p="$pid" '$1 == p { print $4 }' "$here/ps.table" 2>/dev/null)"
      exit 0 ;;
    *comm=* | *pgid=*) cat "$here/ps.table" 2>/dev/null; exit 0 ;;
    *) [ -z "$prev" ] || [ "$prev" = "-p" ] && pid=$a ;;
  esac
  prev=$a
done
exit 1
SH

  # Default foreground table: one claude-family agent inside the foreground group.
  printf '%s\n' '100 100 100 claude1' > "$fakebin/ps.table"
  printf '0:10\n' > "$fakebin/cputime.txt"

  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# canned backlog: lines "<id> <state>" in $FAKE_AXI_STATES
set -u
if [ "${1:-}" = show ]; then
  id=${2:-}
  state=$(awk -v i="$id" '$1 == i { print $2 }' "${FAKE_AXI_STATES:-/dev/null}" 2>/dev/null)
  printf 'task:\n  id: %s\n  state: %s\n' "$id" "${state:-none}"
  exit 0
fi
exit 1
SH

  cat > "$fakebin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${2:-}" >> "${FM_ANSTOSS_SENT_LOG:?FM_ANSTOSS_SENT_LOG unset}"
exit 0
SH

  chmod +x "$fakebin"/tmux "$fakebin"/ps "$fakebin"/tasks-axi "$fakebin"/fm-send.sh
  : > "$dir/capture.txt"
  : > "$dir/windows.txt"
  : > "$dir/axi.states"
  printf '%s\n' "$dir"
}

# Standard ship-lane meta pointing at the fake backend world. The worktree is
# deliberately nonexistent, so crew_run_progressed refuses early and the CPU
# delta stays the only child-process evidence under test.
write_lane_meta() {  # <case-dir> <id> [harness] [kind]
  local dir=$1 id=$2 harness=${3:-claude-ox} kind=${4:-ship}
  fm_write_meta "$dir/state/$id.meta" \
    "window=test:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=/nonexistent-$id" \
    "project=/nonexistent" \
    "harness=$harness" \
    "kind=$kind"
}

# Run ONE sweep against a case. Extra args become extra env assignments
# (env VAR=v ... after the first positional).
sweep() {  # <case-dir> [ENV=v ...]
  local dir=$1
  shift
  env \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_ANSTOSS_SEND_BIN="$dir/fakebin/fm-send.sh" \
    FM_ANSTOSS_SENT_LOG="$dir/sent.log" \
    FAKE_AXI_STATES="$dir/axi.states" \
    FM_FAKE_TMUX_WINDOWS="$dir/windows.txt" \
    FM_FAKE_TMUX_CAPTURE="$dir/capture.txt" \
    PATH="$dir/fakebin:$PATH" \
    "$@" \
    "$ANSTOSS" check
}

seed_lane() {  # <case-dir> <id> [harness]
  local dir=$1 id=$2
  printf '%s in_flight\n' "$id" >> "$dir/axi.states"
  printf 'fm-%s\n' "$id" >> "$dir/windows.txt"
  : > "$dir/state/$id.status"
}

test_standing_lane_is_nudged_on_second_sighting() {
  local dir id=stehend out
  dir=$(make_anstoss_case standing-nudge)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/capture.txt"

  out=$(sweep "$dir")
  [ ! -s "$dir/sent.log" ] || fail "first sighting already sent a nudge (baseline must seed first)"
  [ -z "$out" ] || fail "first sighting printed a captain-facing line: $out"

  out=$(sweep "$dir")
  [ -s "$dir/sent.log" ] || fail "second sighting did not send the stage-1 nudge"
  grep -q "^$id	" "$dir/sent.log" || fail "nudge was not addressed to the standing lane"
  grep -q "Endbedingung" "$dir/sent.log" || fail "nudge lacks its written end condition"
  grep -q "committet" "$dir/sent.log" || fail "nudge does not demand artifact-first verification"
  [ -z "$out" ] || fail "stage-1 nudge woke firstmate anyway: $out"
  [ "$(cat "$dir/state/.anstoss-count-$id")" = 1 ] || fail "counter after first nudge is not 1"

  pass "a standing lane is seeded once, then automatically nudged with an end condition"
}

test_working_marker_lane_is_never_nudged() {
  local dir id=arbeiter
  dir=$(make_anstoss_case working-marker)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  # Working claude pane: the adapter-verified busy token is on screen.
  printf 'esc to interrupt\n╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "a pane carrying esc-to-interrupt was nudged"

  pass "a lane with the harness working marker is never nudged"
}

# Each remaining adapter-verified token keeps its own lane quiet, and a
# harness with NO verified rendered marker contributes no pane signal at all
# (its liveness verdict rides on children/waits instead).
test_marker_vocabulary_per_harness() {
  local dir id probe
  for probe in "grok:Ctrl+c:cancel" "cursor:ctrl+c to stop"; do
    id="marker-${probe%%:*}"
    dir=$(make_anstoss_case "marker-${probe%%:*}")
    write_lane_meta "$dir" "$id" "${probe%%:*}"
    seed_lane "$dir" "$id"
    printf '%s\n╭───╮\n│ > │\n╰───╯\n' "${probe#*:}" > "$dir/capture.txt"
    sweep "$dir" >/dev/null
    sweep "$dir" >/dev/null
    [ ! -s "$dir/sent.log" ] || fail "a ${probe%%:*} pane carrying its verified token was nudged"
  done

  # Unknown-marker harness (codex): no pane vocabulary exists, so the ladder
  # must still REACH such a lane through the vacuous marker condition - its
  # working verdict rides on process evidence instead.
  id=ohnevokabel
  dir=$(make_anstoss_case marker-codex)
  write_lane_meta "$dir" "$id" codex
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ -s "$dir/sent.log" ] || fail "a standing markerless-harness lane never reached the ladder"

  # ...and its child-process evidence still protects it from a false nudge.
  id=ohnevokabel2
  dir=$(make_anstoss_case marker-codex-cpu)
  write_lane_meta "$dir" "$id" codex
  seed_lane "$dir" "$id"
  printf '0:10\n' > "$dir/fakebin/cputime.txt"
  sweep "$dir" >/dev/null
  printf '0:52\n' > "$dir/fakebin/cputime.txt"
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "a markerless-harness lane with accruing children was nudged"

  pass "each adapter-verified token silences its own lane; markerless harnesses run on process evidence"
}

test_ci_waiting_children_are_work_evidence() {
  local dir id=ciwarter out
  dir=$(make_anstoss_case ci-waiting)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"

  sweep "$dir" >/dev/null                              # seeds the CPU baseline
  printf '0:47\n' > "$dir/fakebin/cputime.txt"         # children accrued CPU
  out=$(sweep "$dir")
  [ ! -s "$dir/sent.log" ] || fail "a lane with accruing child CPU was nudged"
  [ -z "$out" ] || fail "CPU-working lane printed anything: $out"

  pass "a lane whose children accrue CPU across the interval counts as working"
}

test_declared_wait_silences_the_lane() {
  local dir id=warter
  dir=$(make_anstoss_case declared-wait)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-wait.sh" declare "$id" --reason "upstream release pending" --until +3600 >/dev/null

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "an actively declared machine wait was nudged"

  pass "an active machine wait field silences nudges until its deadline"
}

test_terminal_status_closes_the_lane() {
  local dir id=fertig
  dir=$(make_anstoss_case terminal-status)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  printf 'done: PR https://example.test/pr/9 checks green\n' >> "$dir/state/$id.status"

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "a terminally reported lane was nudged"

  pass "a lane whose status ends on a terminal verb is left alone"
}

test_api_error_far_above_prompt_is_reported_not_nudged() {
  local dir id=oxfehler out i
  dir=$(make_anstoss_case api-error-positive)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"

  # POSITIVE fixture from the 2026-08-24 ~17:5x CEST incident class: the API
  # Error banner renders far above the input box, where the hand-sweep's tail
  # cut was blind for 2 of 3 standing windows. Sixty blank lines sit between
  # error and composer to prove the FULL surface is read.
  {
    printf 'API Error (Request timed out, no request id received)\n'
    for i in $(seq 1 60); do printf '\n'; done
    printf '? Retry  ·  esc to clear\n'
    printf '╭──────────────────────╮\n'
    printf '│ >                    │\n'
    printf '╰──────────────────────╯\n'
  } > "$dir/capture.txt"

  out=$(sweep "$dir")
  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "an O-0018 API-error pane was silently nudged"
  printf '%s\n' "$out" | grep -q "O-0018" || fail "the API-error finding was not reported to firstmate"
  printf '%s\n' "$out" | grep -q "API Error" || fail "the report does not carry the evidence line"

  # One report per incident: the identical image stays quiet on re-reads.
  out=$(sweep "$dir")
  if printf '%s' "$out" | grep -q "O-0018"; then
    fail "the same incident was reported twice"
  fi

  pass "a full-surface API-error pane is co-reported as O-0018 exactly once, never nudged"
}

test_dead_endpoint_is_skipped_entirely() {
  local dir id=tot out
  dir=$(make_anstoss_case dead-endpoint)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  # Foreground group is shells only -> confident dead verdict.
  printf '%s\n' '200 300 300 bash' > "$dir/fakebin/ps.table"

  out=$(sweep "$dir")
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "a dead endpoint was nudged into the void"
  [ -z "$out" ] || fail "dead endpoint printed anything: $out"

  pass "a dead endpoint is left to stuck-recovery, never nudged"
}

test_secondmate_windows_are_out_of_scope() {
  local dir id=kollege
  dir=$(make_anstoss_case secondmate-excluded)
  fm_write_meta "$dir/state/$id.meta" \
    "window=test:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=/nonexistent" \
    "harness=claude-ox" \
    "kind=secondmate"
  printf '%s in_flight\n' "$id" >> "$dir/axi.states"
  printf 'fm-%s\n' "$id" >> "$dir/windows.txt"
  : > "$dir/state/$id.status"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "an idle secondmate was nudged"

  pass "secondmate windows stay outside the Automat's scope"
}

test_counter_and_stage2_escalation_fire_together() {
  local dir id=eskalation out
  dir=$(make_anstoss_case counter-escalation)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"

  sweep "$dir" >/dev/null                       # seed
  sweep "$dir" >/dev/null                       # nudge #1 (silent)
  [ "$(cat "$dir/state/.anstoss-count-$id")" = 1 ] || fail "counter is not 1 after the first nudge"

  sleep 1.1                                     # against FM_ANSTOSS_INTERVAL=1 below
  out=$(sweep "$dir" FM_ANSTOSS_INTERVAL=1)
  printf '%s\n' "$out" | grep -q "2. Anstoss wirkungslos" ||
    fail "unchanged situation did not escalate on the second ineffective nudge"
  printf '%s\n' "$out" | grep -q "$id" || fail "escalation does not name the lane"
  [ "$(cat "$dir/state/.anstoss-count-$id")" = 2 ] || fail "counter is not 2 after escalation"

  sleep 1.1
  out=$(sweep "$dir" FM_ANSTOSS_INTERVAL=1)
  printf '%s\n' "$out" | grep -q "3. Anstoss wirkungslos" || fail "escalation did not repeat on the third cycle"

  pass "the ladder counts per lane and escalates to firstmate from the second ineffective nudge"
}

test_refuted_nudge_extends_the_interval_l34() {
  local dir id=widerlegt sends_before sends_after
  dir=$(make_anstoss_case refuted-interval)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"

  sweep "$dir" >/dev/null                        # seed
  sweep "$dir" >/dev/null                        # nudge #1
  sends_before=$(wc -l < "$dir/sent.log")

  # The lane turns out WORKING right after our nudge: refuted (L34).
  printf 'esc to interrupt\n╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  sweep "$dir" >/dev/null
  sends_after=$(wc -l < "$dir/sent.log")
  [ "$sends_before" = "$sends_after" ] || fail "recovery itself produced another nudge"
  [ "$(cat "$dir/state/.anstoss-backoff-$id")" = 1 ] || fail "refutation did not record one doubling"

  # Standing again immediately: the doubled interval must keep quiet...
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  sweep "$dir" FM_ANSTOSS_INTERVAL=1 >/dev/null
  [ "$(wc -l < "$dir/sent.log")" = "$sends_after" ] || fail "the extended interval did not silence the immediate re-nudge"

  # ...until the doubled interval has actually passed.
  sleep 2.1
  sweep "$dir" FM_ANSTOSS_INTERVAL=1 >/dev/null
  [ "$(wc -l < "$dir/sent.log")" -gt "$sends_after" ] || fail "no nudge even after the doubled interval passed"

  pass "a refuted nudge doubles that lane's interval before the next automatic nudge"
}

test_terminal_close_resets_counter_and_backoff() {
  local dir id=schluss
  dir=$(make_anstoss_case terminal-reset)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null                        # nudge #1
  printf 'esc to interrupt\n' > "$dir/capture.txt"
  sweep "$dir" >/dev/null                        # refuted -> backoff recorded
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  printf 'done: landed with evidence\n' >> "$dir/state/$id.status"
  sweep "$dir" >/dev/null                        # terminal close resets everything
  [ ! -e "$dir/state/.anstoss-backoff-$id" ] || fail "terminal close kept the backoff"
  [ ! -e "$dir/state/.anstoss-count-$id" ] || fail "terminal close kept the counter"

  pass "a terminal close resets counter, fingerprint, and interval extension"
}

test_fleet_stop_silences_everything() {
  local dir id=ruhe
  dir=$(make_anstoss_case fleet-stop)
  write_lane_meta "$dir" "$id"
  seed_lane "$dir" "$id"
  printf '╭───╮\n│ > │\n╰───╯\n' > "$dir/capture.txt"
  touch "$dir/state/.fleet-stop"

  sweep "$dir" >/dev/null
  sweep "$dir" >/dev/null
  [ ! -s "$dir/sent.log" ] || fail "fleet stop did not silence the Automat"

  pass "fleet stop silences every nudge"
}

test_arm_writes_and_registers_the_shim() {
  local dir out
  dir=$(make_anstoss_case arm-shim)

  out=$(env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$dir/fakebin:$PATH" "$ANSTOSS" arm)
  printf '%s\n' "$out" | grep -q "armed: state/anstoss.check.sh" || fail "arm did not report success: $out"
  [ -f "$dir/state/anstoss.check.sh" ] || fail "shim was not written"
  [ -f "$dir/state/anstoss.check-trust" ] || fail "trust binding was not written"
  grep -q "fleet-stop" "$dir/state/anstoss.check.sh" || fail "shim lacks the fleet-stop guard"
  grep -q "check$" "$dir/state/anstoss.check.sh" || fail "shim does not exec the checker"

  out=$(env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ANSTOSS" disarm)
  printf '%s\n' "$out" | grep -q "disarmed" || fail "disarm did not report: $out"
  [ ! -e "$dir/state/anstoss.check.sh" ] && [ ! -e "$dir/state/anstoss.check-trust" ] ||
    fail "disarm left artifacts behind"

  pass "arm writes and registers the guarded shim; disarm removes both halves"
}

for t in \
  test_standing_lane_is_nudged_on_second_sighting \
  test_working_marker_lane_is_never_nudged \
  test_marker_vocabulary_per_harness \
  test_ci_waiting_children_are_work_evidence \
  test_declared_wait_silences_the_lane \
  test_terminal_status_closes_the_lane \
  test_api_error_far_above_prompt_is_reported_not_nudged \
  test_dead_endpoint_is_skipped_entirely \
  test_secondmate_windows_are_out_of_scope \
  test_counter_and_stage2_escalation_fire_together \
  test_refuted_nudge_extends_the_interval_l34 \
  test_terminal_close_resets_counter_and_backoff \
  test_fleet_stop_silences_everything \
  test_arm_writes_and_registers_the_shim; do
  "$t"
done
