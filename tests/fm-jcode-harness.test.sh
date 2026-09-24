#!/usr/bin/env bash
# Behavior tests for the verified jcode crewmate adapter.
#
# jcode is the ONLY verified adapter whose interrupt key is not Escape and whose
# interrupt doubles as quit when idle, so the control-fact assertions here are
# load-bearing safety checks rather than documentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry; drop ambient
# ones so a suite run from inside another harness cannot skew the verdict.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

TMP_ROOT=$(fm_test_tmproot fm-jcode-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT
command -v jq >/dev/null || fail "test needs jq"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# --------------------------------------------------------------- control facts
[ "$(fm_control_interrupt_key jcode)" = C-c ] \
  || fail "jcode must interrupt on C-c, never the shared Escape default"
pass "jcode interrupts on C-c, not Escape"

[ "$(fm_control_interrupt_repeat jcode)" = 1 ] || fail "jcode interrupt repeat must be 1"
[ -z "$(fm_control_interrupt_clear_key jcode)" ] || fail "jcode needs no composer clear key"
[ "$(fm_control_interrupt_ack_source jcode)" = none ] \
  || fail "jcode must not claim a cancellation ack it has not verified"
pass "jcode interrupt mechanics: single press, no clear key, no ack claim"

[ "$(fm_control_exit_command jcode)" = /quit ] || fail "jcode exits on /quit"
[ "$(fm_control_harness_family jcode)" = jcode ] || fail "jcode resolves to its own family"
fm_control_harness_supported jcode || fail "jcode must be a supported harness"
pass "jcode exit command, family, and supported status"

fm_control_harness_supports_kind jcode ship || fail "jcode must run a ship"
fm_control_harness_supports_kind jcode scout || fail "jcode must run a scout"
if fm_control_harness_supports_kind jcode secondmate; then
  fail "jcode has no primary supervision protocol and must be refused as a secondmate"
fi
pass "jcode is a crewmate/scout adapter and is refused as a secondmate"

case "$(fm_control_harness_wiring_paths jcode /wt /state tid)" in
  */state/tid.jcode-bridge.pid) ;;
  *) fail "jcode per-task wiring must be the bridge pidfile so relaunch can clear it" ;;
esac
pass "jcode per-task wiring path is the bridge pidfile"

# ----------------------------------------------------------------- busy source
case " $(fm_busy_sources_for_harness jcode) " in
  *" jcode-debug "*) ;;
  *) fail "jcode semantic source must be jcode-debug" ;;
esac
fm_busy_source_trusted jcode jcode-debug || fail "jcode must trust jcode-debug"
if fm_busy_source_trusted claude jcode-debug; then
  fail "jcode-debug must never classify another harness task"
fi
if fm_busy_source_trusted jcode claude-hook; then
  fail "jcode must not trust another adapter source"
fi
pass "jcode-debug is trusted for jcode only, in both directions"

STATE="$TMP_ROOT/state"; mkdir -p "$STATE"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" t1 --state idle --source fm-spawn --event launch-brief) \
  || fail "could not arm a jcode task"
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" t1 busy --gen "$GEN" --source jcode-debug --event turn-start >/dev/null \
  || fail "jcode-debug busy event refused"
[ "$(fm_busy_classify herdr no-ep jcode t1 "$STATE")" = "busy jcode-debug" ] \
  || fail "a jcode-debug busy record must classify busy"
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" t1 idle --gen "$GEN" --source jcode-debug --event turn-end >/dev/null \
  || fail "jcode-debug idle event refused"
[ "$(fm_busy_classify herdr no-ep jcode t1 "$STATE")" = "idle jcode-debug" ] \
  || fail "a jcode-debug idle record must classify idle"
case "$(fm_busy_classify herdr no-ep claude t1 "$STATE")" in
  unknown*) ;;
  *) fail "a jcode record must never classify a claude task" ;;
esac
pass "jcode-debug records classify busy and idle, and never cross adapters"

if "$ROOT/bin/fm-busy-event.sh" apply "$STATE" t1 busy --gen g-stale-000 \
     --source jcode-debug --event turn-start >/dev/null 2>&1; then
  fail "a superseded incarnation bridge must be refused"
fi
pass "a stale-gen jcode-debug event is refused"

# -------------------------------------------------- composer delivery guard
JCODE_SPIN_ROW=$(printf '\xe2\xa0\xbc 1s')
JCODE_SEND_ROW=$(printf '\xe2\xa0\xb8 sending context 9s')
for row in "$JCODE_SPIN_ROW" "$JCODE_SEND_ROW"; do
  printf '%s\0' "$row" | fm_busy_lines_match jcode \
    || fail "jcode in-flight row must read busy: $row"
done
for row in '   6.2s  107.4 tps' '   write DONE.txt (+1 -0)' '2>'; do
  if printf '%s\0' "$row" | fm_busy_lines_match jcode; then
    fail "jcode settled row must not read busy: $row"
  fi
done
if printf '%s\0' "$JCODE_SPIN_ROW" | fm_busy_lines_match claude; then
  fail "a jcode spinner row must not read busy for another harness"
fi
pass "jcode composer guard matches only in-flight rows, and only for jcode"

# ------------------------------------------- numbered composer classification
# jcode numbers its composer prompt (`1>`, `2>`, `1<>` once submitted) and
# draws a context meter and a status glyph at the row's far right. Left
# unrecognized, every jcode composer reads `unknown`, and bin/fm-control.sh
# refuses to type an exit command unless the composer is PROVEN empty - which
# is how two stalled jcode workers became unrecoverable through the guarded
# path on 2026-09-23. These are the shapes captured live from jcode v0.86.0.
JC_CAPS=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')
JC_METER='3.1k/1.0M ▱▱▱▱▱▱ 0%'
JC_GLYPH=$(printf '\xf3\xb0\x96\x9f')  # U+F059F, jcode's right-hand status glyph

jc_verdict() {  # <composer-row> -> verdict
  local screen
  screen=$(printf 'transcript row\n%s\n' "$1" | fm_composer_jcode_normalize_screen)
  fm_composer_classify_screen "$JC_CAPS" "$screen" 1
}

[ "$(jc_verdict "1>                                   $JC_METER")" = empty ] \
  || fail "an EMPTY jcode composer must classify empty, or the guarded exit path can never stop a jcode agent"
[ "$(jc_verdict "1>                                   $JC_GLYPH")" = empty ] \
  || fail "an empty jcode composer carrying only the status glyph must classify empty"
[ "$(jc_verdict "12>")" = empty ] \
  || fail "a multi-digit jcode turn index must classify empty: the index grows with the conversation"
[ "$(jc_verdict "1<> already submitted")" = pending ] \
  || fail "a submitted jcode row still carries text and must not read empty"
pass "an empty jcode composer classifies empty rather than unknown"

[ "$(jc_verdict "1> draft text here                   $JC_METER")" = pending ] \
  || fail "a jcode composer holding typed text must classify pending so an exit cannot concatenate onto it"
[ "$(jc_verdict "1> draft text here                   $JC_GLYPH")" = pending ] \
  || fail "typed text must still read pending when the row ends in the status glyph"
[ "$(jc_verdict "1> 3.1k/1.0M")" = pending ] \
  || fail "meter-shaped text the operator actually TYPED is content: only the row's furniture tail is stripped"
pass "a typed jcode composer classifies pending, and meter-like typed text is not eaten"

# The dead-shell rule is the reason this is scoped to an identified jcode pane.
# It must survive: an agent that exited leaves a real shell prompt behind, and
# typing an exit command into that shell is exactly what the rule prevents.
[ "$(jc_verdict "> ")" = unknown ] \
  || fail "a bare shell prompt must still read unknown even on a jcode pane: the agent may have exited"
[ "$(jc_verdict "$ ")" = unknown ] \
  || fail "a dollar shell prompt must still read unknown"
pass "the dead-shell rule survives for a bare prompt on a jcode pane"

# The normalization must be a no-op on every other harness's shape, because a
# jcode pane is identified structurally and this must not drift into a
# fleet-wide rewrite if that gate is ever reached wrongly.
for other in '❯ claude row' '› codex row' '⟩ muse row' '2 > 1 is true' '$ x'; do
  jc_row=$other
  fm_composer_jcode_row_normalize_var jc_row
  [ "$jc_row" = "$other" ] \
    || fail "jcode normalization must not touch another harness's row: [$other] became [$jc_row]"
done
pass "jcode composer normalization leaves every other harness's row byte-identical"

# --------------------------------------------------------- quota and detection
JC_QUOTA=$(. "$ROOT/bin/fm-quota-axi-lib.sh" && fm_quota_provider_for_harness jcode)
[ "$JC_QUOTA" = claude ] \
  || fail "jcode must share the claude quota family: it spends the same subscription windows (got '$JC_QUOTA')"
pass "jcode shares the claude quota family"

# Real processes named jcode and jcode-helper, so detection is exercised against
# a live ancestry walk rather than read from the source.
mkdir -p "$TMP_ROOT/names"
for name in jcode jcode-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
JC_ENV_UNSET=(-u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT
  -u CURSOR_INVOKED_AS -u GEMINI_CLI -u FM_OMP_HARNESS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI)
# shellcheck disable=SC2016  # $1 is expanded by the named child shell, not here.
JC_DETECTED=$(env "${JC_ENV_UNSET[@]}" "$TMP_ROOT/names/jcode" -c '"$1"; :' _ "$ROOT/bin/fm-harness.sh")
[ "$JC_DETECTED" = jcode ] \
  || fail "bin/fm-harness.sh must detect a process named jcode as the jcode harness, got '$JC_DETECTED'"
# The helper is orphaned before it walks, so the walk sees only the helper and
# init: on a host running a real jcode session the walk would otherwise climb
# legitimately to that session and say nothing about the helper's own name.
JC_HELPER_OUT="$TMP_ROOT/jcode-helper.out"
# shellcheck disable=SC2016  # $1, $2 and $$ are expanded by the named child shell, not here.
( env "${JC_ENV_UNSET[@]}" "$TMP_ROOT/names/jcode-helper" \
    -c 'sleep 0.3; "$1" ancestry "$$" > "$2.tmp"; mv "$2.tmp" "$2"; :' _ "$ROOT/bin/fm-harness.sh" "$JC_HELPER_OUT" & )
for _ in $(seq 1 50); do [ -f "$JC_HELPER_OUT" ] && break; sleep 0.1; done
[ -f "$JC_HELPER_OUT" ] || fail "the orphaned jcode-helper probe never reported"
JC_DETECTED=$(cat "$JC_HELPER_OUT")
[ "$JC_DETECTED" != 'comm jcode' ] \
  || fail "an unrelated jcode-helper process must not claim the jcode harness"
pass "jcode is detected by its own anchored process name"

# ------------------------------------------------------------------- the bridge
BRIDGE="$ROOT/bin/fm-jcode-busy-bridge.sh"
[ -x "$BRIDGE" ] || fail "the jcode busy bridge must be executable"
WT="$TMP_ROOT/wt"; mkdir -p "$WT"
WT_REAL=$(cd "$WT" && pwd -P)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SESS_FILE="$TMP_ROOT/sessions.json"
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are the GENERATED script body, expanded by the fake when it runs, not here.
{
  echo '#!/usr/bin/env bash'
  echo '[ "${1:-}" = debug ] || exit 0'
  echo "cat '$SESS_FILE' 2>/dev/null || echo '[]'"
} > "$FAKEBIN/jcode"
chmod +x "$FAKEBIN/jcode"
PATH="$FAKEBIN:$PATH"; export PATH

S2="$TMP_ROOT/state2"; mkdir -p "$S2"
GEN2=$("$ROOT/bin/fm-busy-event.sh" arm "$S2" t2 --state idle --source fm-spawn --event launch-brief)

printf '[{"working_dir":"%s","is_processing":true,"status":"running"}]' "$WT_REAL" > "$SESS_FILE"
"$BRIDGE" "$S2" t2 --gen "$GEN2" --working-dir "$WT_REAL" --once >/dev/null 2>&1
grep -q 'state=busy source=jcode-debug' "$S2/t2.busy-state" \
  || fail "the bridge must publish busy while is_processing is true"

printf '[{"working_dir":"%s","is_processing":false,"status":"ready"}]' "$WT_REAL" > "$SESS_FILE"
"$BRIDGE" "$S2" t2 --gen "$GEN2" --working-dir "$WT_REAL" --once >/dev/null 2>&1
grep -q 'state=idle source=jcode-debug' "$S2/t2.busy-state" \
  || fail "the bridge must publish idle when is_processing goes false"
pass "the bridge maps is_processing onto busy and idle for the matching worktree"

SEQ_BEFORE=$(sed -n 's/.*seq=\([0-9]*\).*/\1/p' "$S2/t2.busy-state")
"$BRIDGE" "$S2" t2 --gen "$GEN2" --working-dir "$WT_REAL" --once >/dev/null 2>&1
SEQ_AFTER=$(sed -n 's/.*seq=\([0-9]*\).*/\1/p' "$S2/t2.busy-state")
[ "$SEQ_BEFORE" = "$SEQ_AFTER" ] \
  || fail "the bridge must publish only on transition, never once per poll"
pass "the bridge writes only on a state transition"

OTHER="$TMP_ROOT/other"; mkdir -p "$OTHER"
OTHER_REAL=$(cd "$OTHER" && pwd -P)
printf '[{"working_dir":"%s","is_processing":true,"status":"running"}]' "$OTHER_REAL" > "$SESS_FILE"
S3="$TMP_ROOT/state3"; mkdir -p "$S3"
GEN3=$("$ROOT/bin/fm-busy-event.sh" arm "$S3" t3 --state idle --source fm-spawn --event launch-brief)
"$BRIDGE" "$S3" t3 --gen "$GEN3" --working-dir "$WT_REAL" --once >/dev/null 2>&1
grep -q 'source=fm-spawn' "$S3/t3.busy-state" \
  || fail "a session in a DIFFERENT worktree must not drive this task state"
pass "the bridge attributes state only by matching working_dir"

# A live bridge publishes its pid, and the shared stop (used by both relaunch
# and teardown) must actually end the process, not only delete the file.
printf '[{"working_dir":"%s","is_processing":false,"status":"ready"}]' "$WT_REAL" > "$SESS_FILE"
S4="$TMP_ROOT/state4"; mkdir -p "$S4"
GEN4=$("$ROOT/bin/fm-busy-event.sh" arm "$S4" t4 --state idle --source fm-spawn --event launch-brief)
wait_for_bridge_pidfile() {  # <state> <id> <pid>
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(head -n 1 "$1/$2.jcode-bridge.pid" 2>/dev/null)" = "$3" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
"$BRIDGE" "$S4" t4 --gen "$GEN4" --working-dir "$WT_REAL" >/dev/null 2>&1 &
BRIDGE_A=$!
wait_for_bridge_pidfile "$S4" t4 "$BRIDGE_A" || fail "a running bridge must publish its pid"
fm_control_stop_jcode_bridge "$S4" t4
kill -0 "$BRIDGE_A" 2>/dev/null && fail "stopping a jcode bridge must end the process, not only remove its pidfile"
wait "$BRIDGE_A" 2>/dev/null
[ ! -e "$S4/t4.jcode-bridge.pid" ] || fail "stopping a jcode bridge must remove its pidfile"
pass "stopping a jcode bridge ends the process and removes its pidfile"

# A superseded bridge that exits after its replacement wrote the pidfile must
# leave the replacement's pidfile alone, or the live bridge becomes unstoppable.
"$BRIDGE" "$S4" t4 --gen "$GEN4" --working-dir "$WT_REAL" >/dev/null 2>&1 &
BRIDGE_OLD=$!
wait_for_bridge_pidfile "$S4" t4 "$BRIDGE_OLD" || fail "the superseded bridge never published its pid"
sleep 600 &
BRIDGE_NEW_STANDIN=$!
echo "$BRIDGE_NEW_STANDIN" > "$S4/t4.jcode-bridge.pid"
kill "$BRIDGE_OLD"
for _ in $(seq 1 50); do
  kill -0 "$BRIDGE_OLD" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$BRIDGE_OLD" 2>/dev/null; then
  kill -KILL "$BRIDGE_OLD" "$BRIDGE_NEW_STANDIN" 2>/dev/null
  fail "a bridge must exit on SIGTERM"
fi
wait "$BRIDGE_OLD" 2>/dev/null
[ "$(head -n 1 "$S4/t4.jcode-bridge.pid" 2>/dev/null)" = "$BRIDGE_NEW_STANDIN" ] \
  || fail "a superseded bridge's exit must not delete its replacement's pidfile"
fm_control_stop_jcode_bridge "$S4" t4
kill -0 "$BRIDGE_NEW_STANDIN" 2>/dev/null \
  || fail "the stop must never signal a pid that is not a jcode bridge"
kill "$BRIDGE_NEW_STANDIN" 2>/dev/null; wait "$BRIDGE_NEW_STANDIN" 2>/dev/null
pass "a superseded bridge leaves its replacement's pidfile, and a foreign pid is never signalled"

# ------------------------------------------------------------ refusal behaviour
PRE="$ROOT/bin/fm-jcode-preflight.sh"
[ -x "$PRE" ] || fail "the jcode preflight must be executable"
if JCODE_HOME="$TMP_ROOT/empty-home" "$PRE" >/dev/null 2>&1; then
  fail "preflight must refuse a home whose onboarding has never been completed"
fi
pass "preflight refuses an un-onboarded jcode home rather than wedging a crewmate"

SEED="$ROOT/bin/fm-jcode-seed.sh"
[ -x "$SEED" ] || fail "the jcode seeder must be executable"
if "$SEED" tmux tgt "$WT_REAL" "$TMP_ROOT/no-such-brief.md" >/dev/null 2>&1; then
  fail "the seeder must refuse a missing brief"
fi
pass "the seeder refuses a missing brief rather than launching an uninstructed crewmate"

# ------------------------------------------------ jcode as a PRIMARY harness
# A primary is not spawned by fm-spawn: the captain types it in the pane. What
# it needs is a verified supervision protocol, or it falls back to the generic
# unknown contract and a bounded foreground wait instead of a background arm.

SUPI="$ROOT/bin/fm-supervision-instructions.sh"
[ -x "$SUPI" ] || fail "fm-supervision-instructions.sh must be executable"

JC_SNIPPET="$ROOT/docs/supervision-protocols/jcode.md"
[ -f "$JC_SNIPPET" ] || fail "jcode needs its own supervision protocol snippet"
pass "jcode has a supervision protocol snippet"

JC_RENDER=$("$SUPI" --harness jcode 2>&1)
case "$JC_RENDER" in
  *"Mode: jcode background-notify supervision."*) ;;
  *) fail "jcode must render its OWN supervision mode, not the unknown fallback" ;;
esac
case "$JC_RENDER" in
  *"Unknown harness fallback"*)
    fail "jcode must not fall through to the unknown harness contract" ;;
esac
pass "jcode renders its own supervision mode rather than the unknown fallback"

# wake: true is the whole protocol. Verified on v0.84.0 that jcode's wake field
# carries no default and a prose instruction produced wake=false with no wake
# ever firing, so the snippet must prescribe it literally.
case "$JC_RENDER" in
  *"run_in_background: true"*) ;;
  *) fail "the jcode arm must prescribe run_in_background: true" ;;
esac
case "$JC_RENDER" in
  *"wake: true"*) ;;
  *) fail "the jcode arm must prescribe wake: true explicitly" ;;
esac
case "$JC_RENDER" in
  *"LOAD-BEARING"*) ;;
  *) fail "the snippet must state why wake: true cannot be omitted" ;;
esac
pass "the jcode arm prescribes run_in_background and an explicit wake: true"

case "$JC_RENDER" in
  *"bin/fm-watch-arm.sh"*) ;;
  *) fail "jcode must arm the background watcher, not a foreground wait" ;;
esac
case "$JC_RENDER" in
  *"Never use shell \`&\`"*) ;;
  *) fail "the jcode protocol must forbid shell & for supervision" ;;
esac
pass "jcode arms bin/fm-watch-arm.sh as a tracked background task, never shell &"

JC_REPAIR=$("$SUPI" --harness jcode --repair-line 2>&1)
case "$JC_REPAIR" in
  *jcode*wake:\ true*) ;;
  *) fail "the jcode repair line must name the wake: true requirement: $JC_REPAIR" ;;
esac
pass "the jcode repair line names the wake: true requirement"

case "$JC_RENDER" in
  *"Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh jcode background bash task"*) ;;
  *) fail "jcode needs its own ordinary-wake line; the generic one arms nothing" ;;
esac
pass "jcode has its own ordinary-wake line"

# Registering jcode must not have disturbed any other primary.
for h in claude codex opencode pi grok cursor omp; do
  m=$("$SUPI" --harness "$h" 2>&1 | grep -m1 '^Mode:')
  case "$m" in
    *"Unknown harness fallback"*) fail "$h lost its supervision snippet" ;;
    "") fail "$h rendered no supervision mode" ;;
  esac
done
for h in muse rovo gemini bogus; do
  m=$("$SUPI" --harness "$h" 2>&1 | grep -m1 '^Mode:')
  case "$m" in
    *"Unknown harness fallback"*) ;;
    *) fail "$h must still fall back to the unknown contract, got: $m" ;;
  esac
done
pass "every other harness keeps its own protocol, and unverified ones still fall back"

# ------------------------------------------------- firstmate owns dispatch
# jcode can spawn and coordinate its OWN swarm workers, queue future runs
# (schedule / initiative), and run unattended (ambient). Every one of those
# produces agents with no task record, no worktree, and no supervision, so the
# adapter must make them unreachable and REFUSE rather than quietly repair.

JC_TH="$TMP_ROOT/dispatch-home"
mkdir -p "$JC_TH"
printf '{"launch_count":5}\n' > "$JC_TH/setup_hints.json"
printf '{"account":"fake"}\n' > "$JC_TH/auth.json"

write_jcode_cfg() {  # <swarm> <disabled-list> <ambient>
  printf '[display]\ndebug_socket = true\n\n[features]\nswarm = %s\n\n[tools]\ndisabled = %s\n\n[ambient]\nenabled = %s\n' \
    "$1" "$2" "$3" > "$JC_TH/config.toml"
}
DENIED='["swarm", "schedule", "initiative"]'

write_jcode_cfg true "$DENIED" false
if JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
  fail "preflight must refuse a spawn while [features] swarm = true"
fi
pass "preflight refuses a jcode spawn while swarm is enabled"

for denied_tool in swarm schedule initiative; do
  write_jcode_cfg false '[]' false
  if JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
    fail "preflight must refuse when [tools] disabled does not deny $denied_tool"
  fi
done
pass "preflight refuses unless swarm, schedule and initiative are all denied tools"

write_jcode_cfg false "$DENIED" true
if JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
  fail "preflight must refuse while [ambient] enabled = true: it runs turns outside dispatch"
fi
pass "preflight refuses a jcode spawn while ambient mode is enabled"

write_jcode_cfg false "$DENIED" false
JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1 \
  || fail "preflight must accept a home where firstmate owns dispatch"
pass "preflight accepts a home where firstmate owns dispatch"

# ------------------------------------------------- cold-daemon debug retry
# jcode's daemon starts lazily and a cold one loses the FIRST debug query while
# it is still binding its socket. Observed 2026-09-23: the preflight refused a
# legitimate spawn, and the same command seconds later reported ok untouched.
# The retry window must absorb that without absorbing a genuinely dead daemon.
COLD_BIN="$TMP_ROOT/coldbin"
mkdir -p "$COLD_BIN"
COLD_COUNT="$TMP_ROOT/cold-attempts"

write_cold_jcode() {  # <succeed-on-attempt>  (0 = never answer)
  : > "$COLD_COUNT"
  # shellcheck disable=SC2016  # single quotes are deliberate: this is the GENERATED script body.
  {
    echo '#!/usr/bin/env bash'
    echo '[ "${1:-}" = debug ] || exit 0'
    echo "echo x >> '$COLD_COUNT'"
    echo "n=\$(wc -l < '$COLD_COUNT')"
    echo "[ '$1' -gt 0 ] && [ \"\$n\" -ge '$1' ] || exit 1"
    echo 'echo "[]"'
  } > "$COLD_BIN/jcode"
  chmod +x "$COLD_BIN/jcode"
}

# A daemon that misses its first query and answers the second is a COLD daemon,
# and refusing on it costs a real spawn.
write_cold_jcode 2
PATH="$COLD_BIN:$PATH" JCODE_HOME="$JC_TH" FM_JCODE_DEBUG_WAIT=5 \
  "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1 \
  || fail "preflight must retry a cold daemon's first missed debug query rather than refusing the spawn"
[ "$(wc -l < "$COLD_COUNT")" -ge 2 ] \
  || fail "preflight must actually re-query the daemon, not pass on the first call's failure"
pass "preflight retries a cold daemon rather than refusing a legitimate spawn"

# A daemon that never answers must still refuse: the retry widens the evidence,
# it does not weaken the check.
write_cold_jcode 0
if PATH="$COLD_BIN:$PATH" JCODE_HOME="$JC_TH" FM_JCODE_DEBUG_WAIT=2 \
   "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
  fail "preflight must still refuse when the daemon never answers; the bridge would publish nothing"
fi
[ "$(wc -l < "$COLD_COUNT")" -ge 2 ] \
  || fail "a refusal must come from exhausting the window, not from one attempt"
pass "preflight still refuses a daemon that never answers"

# The window is bounded, so a wedged daemon cannot stall a spawn indefinitely.
write_cold_jcode 0
COLD_START=$(date +%s)
PATH="$COLD_BIN:$PATH" JCODE_HOME="$JC_TH" FM_JCODE_DEBUG_WAIT=2 \
  "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1 || true
COLD_ELAPSED=$(( $(date +%s) - COLD_START ))
[ "$COLD_ELAPSED" -le 15 ] \
  || fail "the debug retry window must stay bounded; a wedged daemon took ${COLD_ELAPSED}s"
pass "the cold-daemon retry window is bounded"

# A real brief and a READY session, so the seeder reaches the effort and the
# refusal is the swarm rule itself rather than an earlier missing-input exit.
printf 'brief\n' > "$TMP_ROOT/swarm-brief.md"
printf '[{"working_dir":"%s","is_processing":false,"status":"ready"}]' "$WT_REAL" > "$SESS_FILE"
for swarm_effort in swarm swarm-deep; do
  SEED_RC=0
  SEED_ERR=$("$ROOT/bin/fm-jcode-seed.sh" tmux tgt "$WT_REAL" "$TMP_ROOT/swarm-brief.md" \
    --effort "$swarm_effort" --timeout 3 2>&1 >/dev/null) || SEED_RC=$?
  [ "$SEED_RC" -eq 1 ] || fail "the seeder must refuse effort $swarm_effort with exit 1, got $SEED_RC: $SEED_ERR"
  case "$SEED_ERR" in
    *"refusing effort '$swarm_effort'"*"firstmate owns dispatch"*) ;;
    *) fail "the seeder must say why $swarm_effort is refused: $SEED_ERR" ;;
  esac
done
pass "the seeder refuses swarm efforts and says why"

# ============================================================================
# END-TO-END: the REAL bin/fm-spawn.sh against a fake tmux pane and a stateful
# fake jcode, so the launch shape, the preflight gate, the typed brief, and the
# busy arming are all exercised together with no live harness session.
# ============================================================================

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# A fake jcode whose `debug sessions` answer FLIPS: it reports a ready session
# until the brief is typed, then reports one that is processing. That is exactly
# the sequence bin/fm-jcode-seed.sh depends on - wait for ready, type, then
# require is_processing as proof the brief actually started a turn - so a seeder
# that skipped either half would fail here.
write_fake_jcode() {  # <fakebin> <wd-file> <marker> [daemon-marker]
  local fakebin=$1 wdfile=$2 marker=$3 daemon=${4-}
  # shellcheck disable=SC2016  # single quotes are deliberate: these lines are the GENERATED script body, expanded by the fake when it runs, not here.
  {
    echo '#!/usr/bin/env bash'
    echo 'if [ "${1:-}" != debug ]; then exit 0; fi'
    if [ -n "$daemon" ]; then
      echo "[ -f '$daemon' ] || { echo 'Debug socket not found; a jcode server must be running' >&2; exit 1; }"
    fi
    echo "wd=\$(cat '$wdfile' 2>/dev/null || true)"
    echo 'if [ -z "$wd" ]; then echo "[]"; exit 0; fi'
    echo "if [ -f '$marker' ]; then proc=true; st=running; else proc=false; st=ready; fi"
    echo 'printf "[{\"working_dir\":\"%s\",\"is_processing\":%s,\"status\":\"%s\",\"session_id\":\"s1\"}]" "$wd" "$proc" "$st"'
  } > "$fakebin/jcode"
  chmod +x "$fakebin/jcode"
}

# The tmux wrapper drops the marker when the BRIEF is typed - matched on the
# operational-input prefix every firstmate brief carries - standing in for the
# turn the composer would start. Matching a bare `send-keys -l` instead fired
# on the LAUNCH COMMAND itself, so the fake reported a busy session before the
# seeder had even polled for a ready one. It deliberately does NOT try to learn
# the worktree from `new-window -c`: fm-spawn issues several -c calls (the
# project dir among them) and the LAST one is not the task worktree, so reading
# it there captured the wrong directory. fm-spawn passes the task worktree to
# the seeder directly, and the fixture seeds that same path.
wrap_fake_tmux_marker() {  # <fakebin> <marker> [daemon-marker]
  local fakebin=$1 marker=$2 daemon=${3-} inner
  inner="$fakebin/tmux-inner"
  mv "$fakebin/tmux" "$inner"
  # shellcheck disable=SC2016  # single quotes are deliberate: these lines are the GENERATED script body, expanded by the fake when it runs, not here.
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '  case "$a" in'
    echo "    *FIRSTMATE_OP*) : > '$marker' ;;"
    [ -z "$daemon" ] || echo "    \". '\"*\"'\") : > '$daemon' ;;"
    echo '  esac'
    echo 'done'
    echo "exec '$inner' \"\$@\""
  } > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
}

seed_fake_jcode_home() {  # <spawn-home-dir>
  local jh="$1/.jcode"
  mkdir -p "$jh"
  printf '{"launch_count":7}
' > "$jh/setup_hints.json"
  printf '{"anthropic_accounts":[{"label":"fake"}]}
' > "$jh/auth.json"
  # A home firstmate will actually accept: debug control on for the busy bridge,
  # and dispatch owned by firstmate - swarm off, the spawning tools denied, and
  # ambient off. Preflight refuses anything less, which is the point.
  {
    printf '[display]
debug_socket = true

'
    printf '[features]
swarm = false

'
    printf '[tools]
disabled = ["swarm", "schedule", "initiative"]

'
    printf '[ambient]
enabled = false
'
  } > "$jh/config.toml"
}

# With a third argument `cold`, no jcode daemon answers until the launch command
# has been sent to the pane, which is how a real machine behaves after a reboot:
# only a launched jcode client brings the server up.
e2e_case() {  # <name> <id> [cold] -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR MARKER
  local name=$1 id=$2 daemon=
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  MARKER="$CASE_DIR/typed.marker"
  WDFILE="$CASE_DIR/wd.txt"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake" claude pi)
  fm_test_spawn_home "$HOME_DIR" jcode
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  seed_fake_jcode_home "$HOME_DIR/user-home"
  # Seed the worktree the seeder will ask about. fm-spawn passes its task
  # worktree, which for this fixture is WT_DIR; the tmux -c capture in the
  # wrapper below overrides it if fm-spawn ever creates a different one.
  (cd "$WT_DIR" && pwd -P) > "$WDFILE"
  [ "${3-}" != cold ] || daemon="$CASE_DIR/daemon.up"
  write_fake_jcode "$FAKEBIN_DIR" "$WDFILE" "$MARKER" "$daemon"
  wrap_fake_tmux_marker "$FAKEBIN_DIR" "$MARKER" "$daemon"
}

E2E_ID=jcode-e2e-1
e2e_case jcode-e2e "$E2E_ID"
LAUNCH_LOG="$CASE_DIR/launch.log"
: > "$LAUNCH_LOG"

E2E_OUT=$(GROK_HOME="$HOME_DIR/grok-home" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$E2E_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
E2E_STATUS=$?

if [ "$E2E_STATUS" -ne 0 ]; then
  printf 'jcode e2e spawn output:\n%s\n' "$E2E_OUT" >&2
  fail "a real fm-spawn of a jcode ship must succeed"
fi
pass "a real fm-spawn of a jcode crewmate succeeds end to end"

# The log records every literal send: line 1 is the LAUNCH COMMAND, line 2 is
# the typed brief. They are asserted separately - checking the whole log for a
# brief path would match the pointer on line 2 and hide a positional on line 1.
E2E_LAUNCH=$(sed -n '1p' "$LAUNCH_LOG" 2>/dev/null || true)
E2E_TYPED=$(sed -n '2p' "$LAUNCH_LOG" 2>/dev/null || true)

case "$E2E_LAUNCH" in
  *jcode*) ;;
  *) fail "the launch command must invoke a resolved jcode binary: $E2E_LAUNCH" ;;
esac
case "$E2E_LAUNCH" in
  *"--provider claude"*) ;;
  *) fail "the launch must pin --provider claude to match the quota family: $E2E_LAUNCH" ;;
esac
case "$E2E_LAUNCH" in
  *"--no-update"*) ;;
  *) fail "the launch must pass --no-update so a crewmate cannot restart itself mid-task" ;;
esac
case "$E2E_LAUNCH" in
  *launch-brief*|*brief.md*|*FIRSTMATE_OP*)
    fail "jcode must NOT receive the brief on the command line; a positional parses as a subcommand: $E2E_LAUNCH" ;;
esac
pass "the jcode launch command is correctly shaped and carries no positional brief"

case "$E2E_TYPED" in
  *FIRSTMATE_OP*launch-brief*) ;;
  *) fail "the brief must be TYPED as an operational-input launch-brief: $E2E_TYPED" ;;
esac
case "$E2E_TYPED" in
  *launch-brief.md*) ;;
  *) fail "the typed pointer must name the brief file on disk: $E2E_TYPED" ;;
esac
pass "the brief is typed as an operational-input pointer at the on-disk brief"

E2E_STATE="$HOME_DIR/state"
[ -f "$E2E_STATE/$E2E_ID.busy-state" ] \
  || fail "a jcode spawn must arm the busy-state contract"
E2E_CLASS=$(fm_busy_classify tmux fake:w jcode "$E2E_ID" "$E2E_STATE")
case "$E2E_CLASS" in
  busy\ fm-spawn|busy\ jcode-debug|idle\ jcode-debug) ;;
  *) fail "a jcode spawn must leave a trusted busy record, got '$E2E_CLASS'" ;;
esac
pass "a jcode spawn arms the busy contract and classifies from a trusted source"

[ -f "$MARKER" ] || fail "the launch brief was never typed into the pane"
pass "the launch brief is typed into the crewmate pane"

run_teardown() {  # <home> <fakebin> <id>
  HOME="$1/user-home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="${TMUX:-fake,1,0}" PATH="$2:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$3" --force 2>&1
}

E2E_BRIDGE_PID=
for _ in $(seq 1 50); do
  E2E_BRIDGE_PID=$(head -n 1 "$E2E_STATE/$E2E_ID.jcode-bridge.pid" 2>/dev/null || true)
  [ -z "$E2E_BRIDGE_PID" ] || break
  sleep 0.1
done
if [ -z "$E2E_BRIDGE_PID" ] || ! kill -0 "$E2E_BRIDGE_PID" 2>/dev/null; then
  fail "a jcode spawn must leave its busy bridge running"
fi
TD_OUT=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$E2E_ID") \
  || fail "teardown of a jcode crewmate failed: $TD_OUT"
if kill -0 "$E2E_BRIDGE_PID" 2>/dev/null; then
  kill "$E2E_BRIDGE_PID" 2>/dev/null
  fail "teardown must stop the jcode busy bridge, or it outlives the task"
fi
[ ! -e "$E2E_STATE/$E2E_ID.jcode-bridge.pid" ] || fail "teardown must remove the bridge pidfile"
pass "teardown stops the jcode busy bridge process"

# jcode is verified as a primary and for crewmate/scout work, but never as a
# secondmate, so a secondmate spawn is refused outright.
SM_ID=jcode-secondmate-1
e2e_case jcode-secondmate "$SM_ID"
SM_RC=0
SM_OUT=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SM_ID" --secondmate jcode 2>&1) || SM_RC=$?
[ "$SM_RC" -ne 0 ] || fail "a jcode secondmate spawn must be refused"
case "$SM_OUT" in
  *"jcode is verified as a primary"*"not verified as a secondmate"*) ;;
  *) fail "the jcode secondmate refusal must state its reason: $SM_OUT" ;;
esac
pass "fm-spawn refuses a jcode secondmate"

# A home the preflight refuses must never reach a pane: the refusal has to come
# before the launch command is sent, or jcode is already open in the pane.
REF_ID=jcode-refused-1
e2e_case jcode-refused "$REF_ID"
sed -i 's/^swarm = false/swarm = true/' "$HOME_DIR/user-home/.jcode/config.toml"
REF_LOG="$CASE_DIR/launch.log"
: > "$REF_LOG"
REF_RC=0
REF_OUT=$(FM_FAKE_LAUNCH_LOG="$REF_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$REF_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1) || REF_RC=$?
[ "$REF_RC" -ne 0 ] || fail "a jcode spawn on a home with swarm enabled must be refused"
case "$REF_OUT" in
  *"jcode preflight refused"*) ;;
  *) fail "the refusal must come from the jcode preflight: $REF_OUT" ;;
esac
[ ! -s "$REF_LOG" ] || fail "a preflight-refused jcode spawn must not send a launch command: $(cat "$REF_LOG")"
pass "a preflight refusal stops a jcode spawn before anything launches"

# The first jcode spawn after a reboot finds no daemon running. The live daemon
# probe can only pass once the launch has started one, so that spawn must still
# succeed rather than be refused for a daemon it was about to start.
COLD_ID=jcode-cold-1
e2e_case jcode-cold "$COLD_ID" cold
COLD_LOG="$CASE_DIR/launch.log"
: > "$COLD_LOG"
COLD_RC=0
COLD_OUT=$(FM_JCODE_DEBUG_WAIT=2 FM_FAKE_LAUNCH_LOG="$COLD_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$COLD_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1) || COLD_RC=$?
[ "$COLD_RC" -eq 0 ] || fail "a jcode spawn with no daemon running yet must succeed: $COLD_OUT"
[ -f "$CASE_DIR/daemon.up" ] || fail "the cold case must start with no daemon until the launch"
[ -f "$MARKER" ] || fail "a cold-daemon jcode spawn must still deliver its brief"
COLD_TD=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$COLD_ID") \
  || fail "teardown of the cold-daemon jcode crewmate failed: $COLD_TD"
pass "a jcode spawn succeeds when no daemon is running until the launch starts it"

# ============================================================================
# REAL TMUX: bin/fm-tmux-lib.sh's fm_tmux_composer_state against a live pane
# whose foreground process is named jcode and renders jcode's numbered composer.
# ============================================================================
if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found; jcode composer backend regression not run"
else
  JC_TMUX=$(command -v tmux)
  JC_SOCK="fm-jcode-composer-$$"
  JC_SHIM="$TMP_ROOT/tmux-shim"
  mkdir -p "$JC_SHIM"
  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$JC_TMUX" "$JC_SOCK" > "$JC_SHIM/tmux"
  chmod +x "$JC_SHIM/tmux"
  trap '"$JC_TMUX" -L "$JC_SOCK" kill-server >/dev/null 2>&1; rm -rf "$TMP_ROOT"' EXIT

  # A pane "agent" that draws one transcript row, then the composer row with the
  # cursor left on it, and stays in the foreground. #!/bin/bash (not env) keeps
  # the process name equal to the script's own name.
  write_pane_agent() {  # <dir> <name>
    mkdir -p "$1"
    # shellcheck disable=SC2016  # the generated script expands $1 when it runs.
    printf '#!/bin/bash\nprintf "transcript row\\n%%s" "$(cat "$1")"\nwhile :; do sleep 60; done\n' > "$1/$2"
    chmod +x "$1/$2"
  }
  write_pane_agent "$TMP_ROOT/pane-jcode" jcode
  write_pane_agent "$TMP_ROOT/pane-other" other-agent

  composer_state_for() {  # <agent-path> <row> -> verdict
    local row_file="$TMP_ROOT/pane-row" win out i=0
    printf '%s' "$2" > "$row_file"
    win="w$RANDOM"
    PATH="$JC_SHIM:$PATH" tmux new-session -d -s "$win" -x 120 -y 10 "$1" "$row_file" \
      || { echo tmux-failed; return 0; }
    while [ "$i" -lt 50 ]; do
      case "$(PATH="$JC_SHIM:$PATH" tmux capture-pane -p -t "$win" 2>/dev/null)" in
        *transcript*) break ;;
      esac
      sleep 0.1; i=$((i + 1))
    done
    out=$(PATH="$JC_SHIM:$PATH" bash -c '. "$1/bin/fm-tmux-lib.sh" && fm_tmux_composer_state "$2"' _ "$ROOT" "$win")
    PATH="$JC_SHIM:$PATH" tmux kill-session -t "$win" >/dev/null 2>&1
    printf '%s' "$out"
  }

  JC_EMPTY_ROW="1>                                   $JC_METER"
  JC_TYPED_ROW="1> draft text here                   $JC_METER"
  v=$(composer_state_for "$TMP_ROOT/pane-jcode/jcode" "$JC_EMPTY_ROW")
  [ "$v" = empty ] || fail "an empty jcode composer in a live jcode pane must classify empty through the backend, got '$v'"
  v=$(composer_state_for "$TMP_ROOT/pane-jcode/jcode" "$JC_TYPED_ROW")
  [ "$v" = pending ] || fail "a typed jcode composer in a live jcode pane must classify pending through the backend, got '$v'"
  v=$(composer_state_for "$TMP_ROOT/pane-jcode/jcode" "> ")
  [ "$v" = unknown ] || fail "a bare prompt must stay unknown even in a jcode pane, got '$v'"
  v=$(composer_state_for "$TMP_ROOT/pane-other/other-agent" "$JC_EMPTY_ROW")
  [ "$v" = unknown ] || fail "jcode's composer shape must not be recognised in a pane that is not jcode, got '$v'"
  pass "fm_tmux_composer_state reads jcode's composer only in a pane whose foreground process is jcode"
fi

echo "all fm-jcode-harness tests passed"
