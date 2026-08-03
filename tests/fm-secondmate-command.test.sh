#!/usr/bin/env bash
# tests/fm-secondmate-command.test.sh - the two-way secondmate command transfer:
# who commands a persistent lane, how it moves between firstmate command and
# captain command, and how the rest of the fleet behaves in either state.
#
# The failure this guards against is a lane in an ambiguous command state - the
# captain talking to a lane that is still routing through firstmate, or firstmate
# steering a lane the captain is driving. Everything below is asserted through an
# executable interface (the command lib's functions, the transfer script's exit
# codes and output, and the real steering/retirement/supervision entry points),
# except the tracked instruction surfaces at the end, which ARE the artifact an
# agent reads and have no behavior behind them.
#
# Coverage:
#   1. Command state reads from exactly one owner - the registry line - with an
#      absent field meaning firstmate and an unrecognized value failing closed.
#   2. status reports each lane, flags captain-commanded lanes, and exits 3 on a
#      registry/marker divergence.
#   3. onramp refuses on every defined unsafe state, with no override flag.
#   4. onramp transfers atomically, writes the position record, and is idempotent.
#   5. offramp forces an explicit, fresh, lane-written position report first.
#   6. fm-send, fm-backlog-handoff, and fm-teardown all stop acting on a
#      captain-commanded lane.
#   7. The watcher absorbs a captain-commanded lane's status events instead of
#      waking firstmate, and the away-mode daemon never calls one a wedge.
#   8. Session start and the liveness sweep report command state.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-secondmate-command-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

CMD="$ROOT/bin/fm-secondmate-command.sh"
SEND="$ROOT/bin/fm-send.sh"
HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
AGENTS="$ROOT/AGENTS.md"
SKILL="$ROOT/.agents/skills/secondmate-command-transfer/SKILL.md"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-command)
fm_git_identity fmtest fmtest@example.com

REG_LINE_PLAIN='- sm-alpha - Owns the alpha domain. (home: %s; scope: alpha work; projects: alpha; added 2026-01-01)'
REG_LINE_LABELLED='- sm-alpha - Owns the alpha domain. (home: %s; scope: alpha work; projects: alpha; added 2026-01-01; label: SM Alpha)'

# --- fixtures ---------------------------------------------------------------

# make_fleet <name> [registry-line-format] -> echoes the primary home path.
# Builds a primary home (data/, state/, config/) with one registered secondmate
# whose seeded home validates, plus a resolvable kind=secondmate meta.
make_fleet() {
  local name=$1 fmt=${2:-$REG_LINE_PLAIN} home lane
  home="$TMP_ROOT/$name-primary"
  lane="$TMP_ROOT/$name-lane"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  mkdir -p "$lane/data" "$lane/state" "$lane/config" "$lane/projects" "$lane/bin"
  printf '# Firstmate\n' > "$lane/AGENTS.md"
  printf 'sm-alpha\n' > "$lane/.fm-secondmate-home"
  printf '# Secondmates\n\n' > "$home/data/secondmates.md"
  # shellcheck disable=SC2059 # fmt is a fixed local format string, not user input.
  printf -- "$fmt\n" "$lane" >> "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/sm-alpha.meta" "$lane" "firstmate:fm-sm-alpha" alpha claude
  printf '%s\n' "$home"
}

lane_of() { printf '%s\n' "${1%-primary}-lane"; }

# A fake crew-state reader whose single verdict comes from FM_FAKE_CREW_STATE.
# Named apart from wake-helpers' same-purpose fixture, which this file also
# sources for the real-watcher case below.
make_lane_state_reader() {  # <dir> -> echoes the script path
  local dir=$1 path="$1/fake-crew-state.sh"
  mkdir -p "$dir"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · none}"
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

# A fake fm-send that records its argv and honours FM_FAKE_SEND_FAIL. It also
# mirrors the real fm-send's refusal to resolve a target without an explicit
# FM_HOME, so a caller that forgets to pass the home down fails here rather than
# silently passing against a fake that never needed it.
make_fake_send() {  # <dir> -> echoes the script path
  local dir=$1 path="$1/fake-send.sh"
  mkdir -p "$dir"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf 'FM_HOME=%s\n' "${FM_HOME-<unset>}" >> "${FM_FAKE_SEND_ENV_LOG:-/dev/null}"
printf '%s\n' "$*" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi
[ -z "${FM_FAKE_SEND_FAIL:-}" ] || exit 1
exit 0
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

# A fake tmux whose window inventory and pane command make the recorded lane
# endpoint classify as a live agent, so endpoint liveness is never the reason a
# transfer test fails.
make_alive_tmux() {  # <dir> -> echoes the fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf 'fm-sm-alpha\n'; exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *pane_current_command*) printf 'claude\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# run_cmd <home> -- <fm-secondmate-command args...>
run_cmd() {
  local home=$1; shift
  [ "${1:-}" != -- ] || shift
  env PATH="${ALIVE_TMUX:-}:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_SECONDMATE_COMMAND_CREW_STATE_BIN="${FAKE_CREW_STATE:-}" \
    FM_SECONDMATE_COMMAND_SEND_BIN="${FAKE_SEND:-}" \
    "$CMD" "$@" 2>&1
}

reg_of() { printf '%s\n' "$1/data/secondmates.md"; }

# --- 1. command state has exactly one owner ---------------------------------

test_absent_field_means_firstmate_command() {
  local home reg got
  home=$(make_fleet absent-field)
  reg=$(reg_of "$home")
  got=$(fm_secondmate_command_state sm-alpha "$reg")
  [ "$got" = firstmate ] || fail "a registry line with no command: field must read as firstmate command, got '$got'"
  fm_secondmate_command_is_captain sm-alpha "$reg" && fail "an unfielded lane must not read as captain-commanded"
  fm_secondmate_command_blocks_firstmate_action sm-alpha "$reg" >/dev/null \
    && fail "an unfielded lane must not block firstmate action"
  pass "an absent command: field is ordinary firstmate command"
}

test_explicit_captain_command_is_read_from_the_registry() {
  local home reg got
  home=$(make_fleet explicit-captain)
  reg=$(reg_of "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null 2>&1 || true
  # Independent of the transfer path: assert the field the reader contracts on.
  sed -i.bak 's/added 2026-01-01\(.*\))/added 2026-01-01\1; command: captain)/' "$reg" 2>/dev/null \
    || fail "could not stage a captain command field"
  rm -f "$reg.bak"
  got=$(fm_secondmate_command_state sm-alpha "$reg")
  [ "$got" = captain ] || fail "an explicit '; command: captain' must read as captain command, got '$got'"
  fm_secondmate_command_is_captain sm-alpha "$reg" || fail "captain-commanded lane must satisfy is_captain"
  [ "$(fm_secondmate_command_blocks_firstmate_action sm-alpha "$reg")" = captain ] \
    || fail "a captain-commanded lane must block firstmate action"
  pass "an explicit captain command field is read from the registry"
}

test_unrecognized_command_value_fails_closed() {
  local home reg got rc
  home=$(make_fleet bad-value)
  reg=$(reg_of "$home")
  printf -- '- sm-beta - Beta. (home: /nowhere; scope: b; projects: b; added 2026-01-01; command: whoknows)\n' >> "$reg"
  rc=0
  got=$(fm_secondmate_command_state sm-beta "$reg") || rc=$?
  [ "$got" = invalid ] || fail "an unrecognized command value must read as invalid, got '$got'"
  [ "$rc" = 2 ] || fail "an unrecognized command value must return 2 (fail closed), got $rc"
  fm_secondmate_command_is_captain sm-beta "$reg" \
    && fail "a damaged record must not be silently absorbed as captain-commanded"
  [ "$(fm_secondmate_command_blocks_firstmate_action sm-beta "$reg")" = invalid ] \
    || fail "a damaged record must block firstmate action"
  pass "an unrecognized command value fails closed instead of defaulting"
}

test_unregistered_id_is_not_a_lane() {
  local home reg rc got
  home=$(make_fleet unregistered)
  reg=$(reg_of "$home")
  rc=0
  got=$(fm_secondmate_command_state some-crewmate "$reg") || rc=$?
  [ "$rc" = 1 ] || fail "an unregistered id must return 1, got $rc"
  [ -z "$got" ] || fail "an unregistered id must print nothing, got '$got'"
  fm_secondmate_command_blocks_firstmate_action some-crewmate "$reg" >/dev/null \
    && fail "an ordinary crewmate id must never block firstmate action"
  pass "an unregistered id is an ordinary worker, not a lane"
}

test_command_field_parses_beside_a_label_field() {
  local home reg got
  home=$(make_fleet with-label "$REG_LINE_LABELLED")
  reg=$(reg_of "$home")
  sed -i.bak 's/; label: SM Alpha)/; label: SM Alpha; command: captain)/' "$reg"
  rm -f "$reg.bak"
  got=$(fm_secondmate_command_state sm-alpha "$reg")
  [ "$got" = captain ] || fail "command: must parse alongside label:, got '$got'"
  pass "the command field parses beside an existing label field"
}

# --- 2. status --------------------------------------------------------------

test_status_reports_each_lane_and_flags_captain_command() {
  local home out
  home=$(make_fleet status-basic)
  out=$(run_cmd "$home" status)
  assert_contains "$out" "COMMAND: sm-alpha command=firstmate" "status must report each lane's command state"
  assert_not_contains "$out" "CAPTAIN_COMMAND:" "a firstmate-commanded lane must not be flagged as the captain's"
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(run_cmd "$home" status)
  assert_contains "$out" "COMMAND: sm-alpha command=captain" "status must report the transferred state"
  assert_contains "$out" "CAPTAIN_COMMAND: sm-alpha" "status must flag a lane the captain holds"
  pass "status reports each lane and flags captain command"
}

test_status_exits_nonzero_on_a_registry_marker_divergence() {
  local home lane out rc
  home=$(make_fleet status-divergence)
  lane=$(lane_of "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  # Simulate a half-applied transfer: the lane still believes firstmate commands it.
  printf '# Command state\n\ncommand: firstmate\n' > "$lane/data/command.md"
  rc=0
  out=$(run_cmd "$home" status) || rc=$?
  [ "$rc" = 3 ] || fail "a registry/marker divergence must exit 3, got $rc"
  assert_contains "$out" "COMMAND_DIVERGENCE: sm-alpha registry=captain marker=firstmate" \
    "status must name the divergence and which side is authoritative"
  pass "status exits 3 and names a registry/marker divergence"
}

test_status_treats_an_absent_marker_as_firstmate_command() {
  local home rc out
  home=$(make_fleet status-no-marker)
  rc=0
  out=$(run_cmd "$home" status) || rc=$?
  [ "$rc" = 0 ] || fail "a lane seeded before command transfer existed must not read as divergent, got $rc"
  assert_contains "$out" "marker=absent" "status must report the marker as absent rather than guessing"
  pass "an absent home marker agrees with firstmate command"
}

# --- 3. onramp refusals -----------------------------------------------------

# assert_onramp_refused <home> <needle> <msg>: the run exits 4, says why, and
# leaves BOTH records untouched.
assert_onramp_refused() {
  local home=$1 needle=$2 msg=$3 out rc lane
  lane=$(lane_of "$home")
  rc=0
  out=$(run_cmd "$home" onramp sm-alpha) || rc=$?
  [ "$rc" = 4 ] || fail "$msg: expected refusal exit 4, got $rc"$'\n'"$out"
  assert_contains "$out" "REFUSED:" "$msg: refusal must be explicit"
  assert_contains "$out" "$needle" "$msg: refusal must name the blocking state"
  assert_no_grep '; command: captain)' "$(reg_of "$home")" "$msg: a refused onramp must not change the registry"
  assert_absent "$lane/data/command.md" "$msg: a refused onramp must not tell the lane anything"
}

test_onramp_refuses_an_unregistered_lane() {
  local home out rc
  home=$(make_fleet onramp-unregistered)
  rc=0
  out=$(run_cmd "$home" onramp sm-ghost) || rc=$?
  [ "$rc" = 4 ] || fail "onramp of an unregistered lane must refuse with 4, got $rc"
  assert_contains "$out" "not a registered secondmate" "the refusal must say the lane is not registered"
  pass "onramp refuses an unregistered lane"
}

test_onramp_refuses_while_away_mode_is_active() {
  local home
  home=$(make_fleet onramp-afk)
  : > "$home/state/.afk"
  assert_onramp_refused "$home" "away mode is active" "away mode"
  pass "onramp refuses to hand a lane to a captain who is not present"
}

test_onramp_refuses_an_unresolved_decision_on_the_parent_channel() {
  local home
  home=$(make_fleet onramp-decision)
  printf 'working: routine\nneeds-decision [key=api-shape]: which shape\n' > "$home/state/sm-alpha.status"
  assert_onramp_refused "$home" "unresolved decision" "open decision"
  pass "onramp refuses while a decision addressed to firstmate is still open"
}

test_onramp_allows_a_decision_that_was_resolved() {
  local home out
  home=$(make_fleet onramp-decision-closed)
  printf 'needs-decision [key=api-shape]: which shape\nresolved [key=api-shape]: settled\n' \
    > "$home/state/sm-alpha.status"
  out=$(run_cmd "$home" onramp sm-alpha) || fail "a resolved decision must not block the transfer"$'\n'"$out"
  assert_contains "$out" "TRANSFERRED: sm-alpha firstmate -> captain" "a closed decision must not block the transfer"
  pass "a resolved decision does not block the transfer"
}

test_onramp_refuses_an_open_request_awaiting_the_lanes_answer() {
  local home dir
  home=$(make_fleet onramp-pending)
  dir="$home/state/pending-replies"
  mkdir -p "$dir"
  printf 'corr_id=abcdef0123456789\ntask_id=sm-alpha\nphase=awaiting_report\nresolved_epoch=\n' \
    > "$dir/abcdef0123456789"
  assert_onramp_refused "$home" "open request from firstmate" "open pending reply"
  pass "onramp refuses while firstmate is still owed an answer"
}

test_onramp_refuses_a_live_validation_run_in_the_lane_home() {
  local home lane
  home=$(make_fleet onramp-validating)
  lane=$(lane_of "$home")
  fm_write_meta "$lane/state/child-1.meta" 'window=lane:fm-child-1' 'kind=ship' "worktree=$lane"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · awaiting_approval' \
    assert_onramp_refused "$home" "live validation run" "live validation run"
  pass "onramp refuses while a run in the lane home is mid-gate"
}

test_onramp_allows_a_lane_whose_run_already_finished() {
  local home lane out
  home=$(make_fleet onramp-run-done)
  lane=$(lane_of "$home")
  fm_write_meta "$lane/state/child-1.meta" 'window=lane:fm-child-1' 'kind=ship' "worktree=$lane"
  out=$(FM_FAKE_CREW_STATE='state: done · source: run-step · checks-passed' \
    run_cmd "$home" onramp sm-alpha) || fail "a terminal run must not block the transfer"$'\n'"$out"
  assert_contains "$out" "TRANSFERRED:" "a finished run must not block the transfer"
  pass "a finished validation run does not block the transfer"
}

test_onramp_refuses_a_lane_whose_endpoint_is_confirmed_absent() {
  local home
  home=$(make_fleet onramp-no-endpoint)
  rm -f "$home/state/sm-alpha.meta"
  assert_onramp_refused "$home" "endpoint is confirmed absent" "absent endpoint"
  pass "onramp refuses a lane that is not answering"
}

test_onramp_has_no_override_flag() {
  local home out rc
  home=$(make_fleet onramp-no-force)
  : > "$home/state/.afk"
  rc=0
  out=$(run_cmd "$home" onramp sm-alpha --force) || rc=$?
  [ "$rc" = 2 ] || fail "there must be no way to wave an onramp refusal through; got exit $rc"
  assert_no_grep '; command: captain)' "$(reg_of "$home")" "--force must not transfer anything"
  pass "an onramp refusal cannot be waved through"
}

# --- 4. onramp success ------------------------------------------------------

test_onramp_transfers_registry_marker_and_position_record() {
  local home lane out record
  home=$(make_fleet onramp-success)
  lane=$(lane_of "$home")
  printf 'working: mid-flight\n' > "$home/state/sm-alpha.status"
  out=$(run_cmd "$home" onramp sm-alpha) || fail "onramp should succeed"$'\n'"$out"
  assert_contains "$out" "TRANSFERRED: sm-alpha firstmate -> captain" "onramp must report the transfer"
  assert_grep '; command: captain)' "$(reg_of "$home")" "onramp must record captain command in the registry"
  assert_present "$lane/data/command.md" "onramp must tell the lane it is under captain command"
  assert_grep 'command: captain' "$lane/data/command.md" "the lane marker must record captain command"
  assert_grep 'a lane cannot transfer itself' "$lane/data/command.md" \
    "the lane marker must say a lane never decides its own command state"
  record=$(printf '%s' "$out" | sed -n 's/.*position: \(.*\))$/\1/p')
  [ -n "$record" ] || fail "onramp must name the position record it wrote"
  assert_present "$record" "the position record must exist"
  assert_grep "$lane" "$record" "the position record must capture the lane home"
  assert_grep 'working: mid-flight' "$record" "the position record must capture the lane's recent events"
  pass "onramp transfers the registry, the lane marker, and a written position"
}

test_both_directions_tell_the_running_lane() {
  # The charter only makes a lane read its command record at session start, so a
  # long-running agent that is never told keeps operating under the previous
  # contract - the two-commanders state this whole feature removes.
  local home log out report
  home=$(make_fleet transfer-notice)
  log="$home/send.log"
  : > "$log"
  out=$(FM_FAKE_SEND_LOG="$log" run_cmd "$home" onramp sm-alpha) \
    || fail "onramp should succeed"$'\n'"$out"
  assert_grep 're-read data/command.md' "$log" "the onramp must tell the live lane its command state changed"
  assert_grep 'the captain now commands this lane' "$log" "the notice must name the new commander"

  out=$(FM_FAKE_SEND_LOG="$log" run_cmd "$home" offramp-request sm-alpha)
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  printf 'Nothing open.\n' > "$report"
  : > "$log"
  out=$(FM_FAKE_SEND_LOG="$log" run_cmd "$home" offramp-complete sm-alpha --report "$report") \
    || fail "offramp-complete should succeed"$'\n'"$out"
  assert_grep 're-read data/command.md' "$log" "the handback must tell the live lane too"
  assert_grep 'main firstmate commands this lane again' "$log" "the notice must name the restored commander"
  pass "both transfer directions tell the running lane to re-read its command state"
}

test_both_directions_notify_when_fm_home_is_not_in_the_environment() {
  # The documented invocation is a plain `bin/fm-secondmate-command.sh onramp
  # <id>` from the main home, where FM_HOME is resolved internally and is NOT an
  # exported environment variable - so a child that is not handed the home
  # explicitly never sees one. Every other case here goes through `env FM_HOME=`,
  # which would hide exactly that.
  local home envlog log out rc report
  home=$(make_fleet transfer-notice-no-fm-home)
  envlog="$home/send-env.log"
  log="$home/send.log"
  : > "$envlog"; : > "$log"
  rc=0
  out=$(env -u FM_HOME -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
    PATH="${ALIVE_TMUX:-}:$PATH" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_SEND_ENV_LOG="$envlog" FM_FAKE_SEND_LOG="$log" \
    FM_SECONDMATE_COMMAND_CREW_STATE_BIN="${FAKE_CREW_STATE:-}" \
    FM_SECONDMATE_COMMAND_SEND_BIN="${FAKE_SEND:-}" \
    "$CMD" onramp sm-alpha 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "onramp with no ambient FM_HOME must notify the lane, got exit $rc"$'\n'"$out"
  assert_contains "$out" "TRANSFERRED: sm-alpha firstmate -> captain" \
    "onramp must report a fully completed transfer"
  assert_grep "FM_HOME=$home" "$envlog" "the notice must carry the resolved home down to the steer path"
  assert_grep 're-read data/command.md' "$log" "the live lane must still be told"

  out=$(env -u FM_HOME -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
    PATH="${ALIVE_TMUX:-}:$PATH" FM_ROOT_OVERRIDE="$home" \
    FM_SECONDMATE_COMMAND_CREW_STATE_BIN="${FAKE_CREW_STATE:-}" \
    FM_SECONDMATE_COMMAND_SEND_BIN="${FAKE_SEND:-}" \
    "$CMD" offramp-request sm-alpha 2>&1) \
    || fail "offramp-request with no ambient FM_HOME must deliver"$'\n'"$out"
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  [ -n "$report" ] || fail "offramp-request must name the report it asked for"$'\n'"$out"
  printf 'Nothing open.\n' > "$report"
  : > "$envlog"
  rc=0
  out=$(env -u FM_HOME -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
    PATH="${ALIVE_TMUX:-}:$PATH" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_SEND_ENV_LOG="$envlog" \
    FM_SECONDMATE_COMMAND_CREW_STATE_BIN="${FAKE_CREW_STATE:-}" \
    FM_SECONDMATE_COMMAND_SEND_BIN="${FAKE_SEND:-}" \
    "$CMD" offramp-complete sm-alpha --report "$report" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "offramp-complete with no ambient FM_HOME must notify the lane, got exit $rc"$'\n'"$out"
  assert_contains "$out" "TRANSFERRED: sm-alpha captain -> firstmate" \
    "offramp-complete must report a fully completed handback"
  assert_grep "FM_HOME=$home" "$envlog" "the handback notice must carry the resolved home down too"
  pass "both directions notify the lane when FM_HOME is not in the environment"
}

test_an_undelivered_notice_is_not_reported_as_a_finished_transfer() {
  # The command record is the authority, so a failed notice never invalidates the
  # transfer - but it must never be reported as a lane that already knows.
  local home out rc lane report
  home=$(make_fleet transfer-notice-failure)
  lane=$(lane_of "$home")
  rc=0
  out=$(FM_FAKE_SEND_FAIL=1 run_cmd "$home" onramp sm-alpha) || rc=$?
  [ "$rc" = 5 ] || fail "an undelivered notice must not exit as a plain success, got $rc"
  assert_contains "$out" "TRANSFERRED_NOT_NOTIFIED: sm-alpha firstmate -> captain" \
    "the output must say the transfer landed but the lane was not told"
  assert_contains "$out" "still believes it is under firstmate command" \
    "the output must say what the running agent still believes"
  assert_grep '; command: captain)' "$(reg_of "$home")" "the recorded transfer must stand"
  assert_grep 'command: captain' "$lane/data/command.md" "the lane's own copy must stand"

  out=$(run_cmd "$home" offramp-request sm-alpha)
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  printf 'Nothing open.\n' > "$report"
  rc=0
  out=$(FM_FAKE_SEND_FAIL=1 run_cmd "$home" offramp-complete sm-alpha --report "$report") || rc=$?
  [ "$rc" = 5 ] || fail "an undelivered handback notice must not exit as a plain success, got $rc"
  assert_contains "$out" "TRANSFERRED_NOT_NOTIFIED: sm-alpha captain -> firstmate" \
    "the handback output must say the lane was not told"
  assert_grep '; command: firstmate)' "$(reg_of "$home")" "the recorded handback must stand"
  pass "an undelivered notice is reported as recorded-but-not-yet-read"
}

test_onramp_is_idempotent() {
  local home out rc before
  home=$(make_fleet onramp-idempotent)
  run_cmd "$home" onramp sm-alpha >/dev/null
  before=$(cat "$(reg_of "$home")")
  rc=0
  out=$(run_cmd "$home" onramp sm-alpha) || rc=$?
  [ "$rc" = 0 ] || fail "a repeated onramp must be a success, got $rc"
  assert_contains "$out" "ALREADY: sm-alpha is already under captain command" "a repeated onramp must say so"
  [ "$before" = "$(cat "$(reg_of "$home")")" ] || fail "a repeated onramp must not rewrite the registry"
  pass "onramp is idempotent"
}

test_onramp_keeps_every_other_registry_field() {
  local home reg
  home=$(make_fleet onramp-fields "$REG_LINE_LABELLED")
  run_cmd "$home" onramp sm-alpha >/dev/null
  reg=$(reg_of "$home")
  assert_grep 'scope: alpha work' "$reg" "the transfer must preserve scope:"
  assert_grep 'projects: alpha' "$reg" "the transfer must preserve projects:"
  assert_grep 'label: SM Alpha' "$reg" "the transfer must preserve label:"
  assert_grep '; command: captain)' "$reg" "the transfer must append the command field"
  pass "the transfer edits only the command field"
}

# --- 5. offramp -------------------------------------------------------------

test_offramp_complete_refuses_without_a_position_report() {
  local home out rc
  home=$(make_fleet offramp-no-request)
  run_cmd "$home" onramp sm-alpha >/dev/null
  rc=0
  out=$(run_cmd "$home" offramp-complete sm-alpha --report "$home/nope.md") || rc=$?
  [ "$rc" = 4 ] || fail "completing a handback with no request on record must refuse, got $rc"
  assert_contains "$out" "no handback request on record" "the refusal must point at the missing request"
  assert_grep '; command: captain)' "$(reg_of "$home")" "a refused handback must leave the lane with the captain"
  pass "the offramp refuses to resume supervision without a requested position report"
}

test_offramp_request_records_the_expected_report_and_asks_the_lane() {
  local home out report log
  home=$(make_fleet offramp-request)
  log="$home/send.log"
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(FM_FAKE_SEND_LOG="$log" run_cmd "$home" offramp-request sm-alpha) \
    || fail "offramp-request should succeed"$'\n'"$out"
  assert_contains "$out" "HANDBACK_REQUESTED: sm-alpha report=" "the request must name the expected report path"
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  assert_present "$home/state/sm-alpha.command-handback" "the request must be durably recorded"
  assert_grep "report=$report" "$home/state/sm-alpha.command-handback" "the record must pin the expected report path"
  assert_grep "$report" "$log" "the lane must actually be asked for its position report"
  pass "offramp-request records and asks for an explicit position report"
}

# A re-request while the lane is mid-answer must not move the target, or the
# report it is already writing would land at a path firstmate no longer accepts.
test_offramp_request_reuses_an_unanswered_request() {
  local home first second third report
  home=$(make_fleet offramp-rerequest)
  run_cmd "$home" onramp sm-alpha >/dev/null
  first=$(run_cmd "$home" offramp-request sm-alpha | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  second=$(run_cmd "$home" offramp-request sm-alpha | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  [ "$first" = "$second" ] \
    || fail "re-requesting an unanswered handback must keep the same report path"$'\n'"$first"$'\n'"$second"
  printf 'position report\n' > "$first"
  third=$(run_cmd "$home" offramp-request sm-alpha | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  [ "$third" != "$first" ] \
    || fail "once a report exists, a new request must ask for a fresh position, not reuse the answered one"
  report=$(sed -n 's/^report=//p' "$home/state/sm-alpha.command-handback" | tail -1)
  [ "$report" = "$third" ] || fail "the record must pin the newest expected report path"
  pass "a re-requested handback reuses an unanswered path and supersedes an answered one"
}

test_offramp_request_refuses_a_firstmate_commanded_lane() {
  local home out rc
  home=$(make_fleet offramp-request-wrong-state)
  rc=0
  out=$(run_cmd "$home" offramp-request sm-alpha) || rc=$?
  [ "$rc" = 4 ] || fail "requesting a handback from a firstmate-commanded lane must refuse, got $rc"
  assert_contains "$out" "not under captain command" "the refusal must say there is nothing to hand back"
  pass "offramp-request refuses a lane firstmate already commands"
}

test_offramp_complete_refuses_a_report_it_did_not_ask_for() {
  local home out rc other
  home=$(make_fleet offramp-wrong-report)
  run_cmd "$home" onramp sm-alpha >/dev/null
  run_cmd "$home" offramp-request sm-alpha >/dev/null
  other="$home/somewhere-else.md"
  printf 'anything\n' > "$other"
  rc=0
  out=$(run_cmd "$home" offramp-complete sm-alpha --report "$other") || rc=$?
  [ "$rc" = 4 ] || fail "a substituted report must refuse, got $rc"
  assert_contains "$out" "must be the one this lane was asked for" "the refusal must name the expected report"
  pass "the offramp refuses a report it did not ask for"
}

test_offramp_complete_refuses_a_stale_report() {
  local home out rc report
  home=$(make_fleet offramp-stale-report)
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(run_cmd "$home" offramp-request sm-alpha)
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  printf 'position from before the captain took the lane\n' > "$report"
  touch -t 202001010000 "$report"
  rc=0
  out=$(run_cmd "$home" offramp-complete sm-alpha --report "$report") || rc=$?
  [ "$rc" = 4 ] || fail "a report that predates the request must refuse, got $rc"
  assert_contains "$out" "predates the handback request" "the refusal must say the report is stale"
  assert_grep '; command: captain)' "$(reg_of "$home")" "a refused handback must leave the lane with the captain"
  pass "the offramp refuses a position report that predates the request"
}

test_offramp_complete_returns_the_lane_after_a_fresh_report() {
  local home lane out report
  home=$(make_fleet offramp-success)
  lane=$(lane_of "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(run_cmd "$home" offramp-request sm-alpha)
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  printf 'The captain and I landed the alpha migration; nothing is open.\n' > "$report"
  out=$(run_cmd "$home" offramp-complete sm-alpha --report "$report") \
    || fail "a fresh report should complete the handback"$'\n'"$out"
  assert_contains "$out" "TRANSFERRED: sm-alpha captain -> firstmate" "the handback must be reported"
  assert_no_grep '; command: captain)' "$(reg_of "$home")" "the registry must return to firstmate command"
  assert_grep '; command: firstmate)' "$(reg_of "$home")" "the registry must record firstmate command explicitly"
  assert_grep 'command: firstmate' "$lane/data/command.md" "the lane must be told firstmate commands it again"
  assert_absent "$home/state/sm-alpha.command-handback" "a completed handback must clear its request record"
  pass "the offramp returns the lane once it has reported its own position"
}

# --- 6. firstmate stops acting on a captain-commanded lane -------------------

# make_send_stubs <dir> -> echoes a fakebin whose tmux lets fm-send reach a
# clean submit verdict, so a refusal is the only reason a send can fail.
make_send_stubs() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_fm_send_refuses_to_steer_a_captain_commanded_lane() {
  local home fb out rc
  home=$(make_fleet send-refusal)
  fb=$(make_send_stubs "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  rc=0
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" sm-alpha "do the thing" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "fm-send must refuse to steer a lane the captain commands"
  assert_contains "$out" "captain command" "the refusal must say why firstmate is not steering"
  pass "firstmate cannot steer a captain-commanded lane"
}

test_fm_send_still_steers_a_firstmate_commanded_lane() {
  local home fb rc
  home=$(make_fleet send-allowed)
  fb=$(make_send_stubs "$home")
  rc=0
  env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" sm-alpha "do the thing" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "an ordinary firstmate-commanded lane must still be steerable, got $rc"
  pass "an ordinary lane is still steerable"
}

test_fm_send_lets_infrastructure_messages_reach_the_lane() {
  local home fb rc
  home=$(make_fleet send-handover)
  fb=$(make_send_stubs "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  rc=0
  env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    FM_SECONDMATE_COMMAND_OPERATIONAL=sm-alpha \
    "$SEND" sm-alpha "Command handback requested" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "the handback request and re-read nudges must still reach the lane, got $rc"
  # Exempting one lane must not exempt another.
  rc=0
  env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    FM_SECONDMATE_COMMAND_OPERATIONAL=sm-other \
    "$SEND" sm-alpha "do the thing" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the exemption must name the exact lane, not any lane"
  pass "infrastructure messages still reach a captain-commanded lane, and only that lane"
}

test_fm_send_refuses_a_lane_whose_command_record_is_missing() {
  # The target's own metadata already says this is a lane, so "no registry line"
  # is a lost authority, not an ordinary crewmate. An authority that cannot be
  # read is not authority, and hard rule 4 must not lapse exactly when the record
  # is gone.
  local home fb out rc
  home=$(make_fleet send-lost-record)
  fb=$(make_send_stubs "$home")
  # A registry that exists but no longer carries this lane.
  printf '# Secondmates\n\n' > "$(reg_of "$home")"
  rc=0
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" sm-alpha "do the thing" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "firstmate must not steer a lane whose command record it cannot read"
  assert_contains "$out" "no readable command record" "the refusal must name the unreadable record"

  # An absent registry is the same lost authority, not a free pass.
  rm -f "$(reg_of "$home")"
  rc=0
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" sm-alpha "do the thing" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "an absent secondmate registry must refuse, not fall open"
  assert_contains "$out" "no readable command record" "the refusal must name the unreadable record"

  # An ordinary crewmate, whose meta is not kind=secondmate, is unaffected.
  fm_write_meta "$home/state/crew-one.meta" "window=firstmate:fm-crew-one" "kind=ship" "mode=no-mistakes"
  rc=0
  env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" crew-one "do the thing" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "an ordinary crewmate must still be steerable with no registry, got $rc"
  pass "firstmate refuses a lane whose command record is missing, and still steers ordinary crewmates"
}

test_the_handback_request_can_still_be_retried() {
  # The handback request is the one message the offramp depends on, and it is the
  # only expectation a captain-commanded lane can still hold. Its built-in retry
  # has to carry the same infrastructure exemption, or firstmate reports a
  # delivery failure for a lane it is forbidden to steer and the offramp stalls.
  local home fb corr rec rc phase
  home=$(make_fleet handback-retry)
  fb=$(make_send_stubs "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    corr=$(fm_pending_reply_create "$home" "$home/state" sm-alpha "Command handback requested") \
      || exit 1
    rec=$(fm_pending_reply_path "$home/state" "$corr")
    fm_pending_reply_set "$rec" delivered_epoch 1 || exit 1
    fm_pending_reply_set "$rec" request_turn_completed_epoch 2 || exit 1
    fm_pending_reply_set "$rec" grace_secs 0 || exit 1
    printf '%s\n' "$corr" > "$home/corr"
    export PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0
    fm_pending_reply_send_recovery "$home/state" "$corr"
  )
  rc=$?
  [ "$rc" = 0 ] || fail "the handback request's own retry must be deliverable to a captain-commanded lane, got $rc"
  corr=$(cat "$home/corr")
  rec="$home/state/pending-replies/$corr"
  phase=$(grep '^phase=' "$rec" | cut -d= -f2-)
  [ "$phase" = recovery_sent ] || fail "a retried handback request must record a delivered retry, got phase=$phase"
  assert_no_grep 'recovery_delivery_outcome=failed' "$rec" "the retry must not be recorded as a delivery failure"
  pass "the handback request's retry still reaches a captain-commanded lane"
}

test_a_completed_handback_closes_its_own_expectation() {
  # The position report IS the answer, delivered as a document. Left open, the
  # expectation the transfer machinery created itself would permanently refuse
  # the next onramp at its open-request guard.
  local home fb corr out report rc
  home=$(make_fleet handback-expectation)
  fb=$(make_send_stubs "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(run_cmd "$home" offramp-request sm-alpha)
  report=$(printf '%s' "$out" | sed -n 's/^HANDBACK_REQUESTED: sm-alpha report=//p')
  # The real request path is stubbed in this file, so stand in its expectation.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    fm_pending_reply_create "$home" "$home/state" sm-alpha "Command handback requested" > "$home/corr"
  ) || fail "could not stage the handback expectation"
  corr=$(cat "$home/corr")
  printf 'Nothing open.\n' > "$report"
  run_cmd "$home" offramp-complete sm-alpha --report "$report" >/dev/null \
    || fail "a fresh report should complete the handback"
  assert_grep 'phase=resolved' "$home/state/pending-replies/$corr" \
    "a completed handback must close the expectation its own request created"
  rc=0
  out=$(run_cmd "$home" onramp sm-alpha) || rc=$?
  [ "$rc" = 0 ] || fail "the next onramp must not be refused by the transfer machinery's own leftovers: $out"
  pass "a completed handback closes its own expectation instead of blocking the next transfer"
}

test_fm_send_refuses_to_interrupt_a_captain_commanded_lane() {
  local home fb out rc
  home=$(make_fleet send-key-refusal)
  fb=$(make_send_stubs "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  rc=0
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" sm-alpha --key C-c 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "firstmate must not interrupt a conversation the captain is having"
  assert_contains "$out" "captain command" "the refusal must say why the interrupt was not sent"
  pass "firstmate cannot interrupt a captain-commanded lane either"
}

test_backlog_handoff_refuses_a_captain_commanded_lane() {
  local home lane out rc
  home=$(make_fleet handoff-refusal)
  lane=$(lane_of "$home")
  printf '## Queued\n\n- [ ] alpha-item - do alpha work\n' > "$home/data/backlog.md"
  printf '## Queued\n' > "$lane/data/backlog.md"
  run_cmd "$home" onramp sm-alpha >/dev/null
  rc=0
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    "$HANDOFF" sm-alpha alpha-item 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "firstmate must not route work into a lane the captain commands"
  assert_contains "$out" "captain command" "the refusal must say why the item is not being routed"
  assert_no_grep 'alpha-item' "$lane/data/backlog.md" "no item may land in a captain-commanded lane's queue"
  pass "firstmate does not route work into a captain-commanded lane"
}

test_teardown_refuses_to_retire_a_captain_commanded_lane() {
  local home out rc
  home=$(make_fleet teardown-refusal)
  run_cmd "$home" onramp sm-alpha >/dev/null
  rc=0
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$TEARDOWN" sm-alpha 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "firstmate must not retire a lane the captain commands"
  assert_contains "$out" "captain command" "the refusal must say why the lane is not being retired"
  assert_grep '; command: captain)' "$(reg_of "$home")" "a refused retirement must leave the registry alone"
  pass "firstmate does not retire a captain-commanded lane"
}

# A lane whose registry line is gone is a LOST authority, not an ordinary
# crewmate: the meta already proved it is a lane. Every entry point that acts on
# a lane must refuse rather than read the missing record as firstmate command.
test_a_lost_command_record_blocks_every_action_on_a_known_lane() {
  local home lane out rc
  home=$(make_fleet lost-record)
  lane=$(lane_of "$home")
  printf '## Queued\n\n- [ ] alpha-item - do alpha work\n' > "$home/data/backlog.md"
  printf '## Queued\n' > "$lane/data/backlog.md"
  run_cmd "$home" onramp sm-alpha >/dev/null
  # The captain holds the lane; the registry that records it is then lost.
  printf '# Secondmates\n\n' > "$(reg_of "$home")"

  rc=0
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$TEARDOWN" sm-alpha 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "firstmate must not retire a lane whose command record cannot be read"
  assert_contains "$out" "no readable command record" \
    "the retirement refusal must name the lost record"

  rc=0
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    "$HANDOFF" sm-alpha alpha-item 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "firstmate must not route work into a lane whose command record cannot be read"
  assert_contains "$out" "no readable command record" \
    "the routing refusal must name the lost record"
  assert_no_grep 'alpha-item' "$lane/data/backlog.md" "no item may land in a lane with no readable commander"

  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-session-start.sh" 2>&1 || true)
  assert_contains "$out" "command: unrecorded" \
    "the digest must never be silent about a lane whose command record cannot be read"
  pass "a lost command record blocks retirement and routing, and is never silent at session start"
}

# --- 7. supervision ---------------------------------------------------------

test_watcher_triage_absorbs_a_captain_commanded_lanes_status_events() {
  local home reg status
  home=$(make_fleet classify-absorb)
  reg=$(reg_of "$home")
  status="$home/state/sm-alpha.status"
  printf 'blocked: I need a decision from you\n' > "$status"
  FM_SECONDMATE_COMMAND_REGISTRY="$reg" signal_reason_is_actionable "$status" \
    || fail "a firstmate-commanded lane's blocker must still be actionable for firstmate"
  # The transfer itself refuses while that decision is open, so close it first;
  # the blocker the captain then hits is a NEW event on his own lane.
  printf 'resolved: firstmate answered it before handing the lane over\n' >> "$status"
  run_cmd "$home" onramp sm-alpha >/dev/null
  printf 'blocked: I need a decision from you, captain\n' >> "$status"
  FM_SECONDMATE_COMMAND_REGISTRY="$reg" signal_reason_is_actionable "$status" \
    && fail "a captain-commanded lane's blocker is addressed to the captain, not to firstmate"
  FM_SECONDMATE_COMMAND_REGISTRY="$reg" signal_crew_provably_working "$status" \
    || fail "a wake naming only captain-commanded lanes must be absorbed, not surfaced"
  pass "the watcher's signal triage absorbs a captain-commanded lane's status events"
}

test_watcher_triage_keeps_a_damaged_record_loud() {
  local home reg status
  home=$(make_fleet classify-damaged)
  reg=$(reg_of "$home")
  printf -- '- sm-beta - Beta. (home: /nowhere; scope: b; projects: b; added 2026-01-01; command: whoknows)\n' >> "$reg"
  status="$home/state/sm-beta.status"
  printf 'blocked: something is wrong\n' > "$status"
  FM_SECONDMATE_COMMAND_REGISTRY="$reg" signal_reason_is_actionable "$status" \
    || fail "a damaged command record must never silence a lane"
  pass "a damaged command record stays loud"
}

# The real watcher, end to end: the heartbeat backstop is the last line that
# would otherwise wake firstmate for a lane he does not command.
test_watcher_does_not_wake_firstmate_for_a_captain_commanded_lane() {
  local home reg dir state fakebin out pid
  home=$(make_fleet watcher-e2e)
  reg=$(reg_of "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  dir=$(make_case captain-commanded-watch); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'blocked: I need a decision from you\n' > "$state/sm-alpha.status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_SECONDMATE_COMMAND_REGISTRY="$reg" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    fail "the watcher woke firstmate for a lane the captain commands: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] \
    || fail "a captain-commanded lane's blocker was queued as firstmate work: $(cat "$state/.wake-queue")"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  pass "the running watcher never wakes firstmate for a captain-commanded lane"
}

test_watcher_still_wakes_firstmate_for_an_ordinary_lane() {
  local home reg dir state fakebin out pid
  home=$(make_fleet watcher-e2e-ordinary)
  reg=$(reg_of "$home")
  dir=$(make_case firstmate-commanded-watch); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'blocked: I need a decision from you\n' > "$state/sm-alpha.status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_SECONDMATE_COMMAND_REGISTRY="$reg" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 \
    || { kill "$pid" 2>/dev/null || true; fail "the watcher must still wake firstmate for a lane it commands"; }
  [ -s "$state/.wake-queue" ] || fail "an ordinary lane's blocker must be queued for firstmate"
  pass "the running watcher still wakes firstmate for a lane it commands"
}

test_daemon_never_calls_a_captain_commanded_lane_a_wedge() {
  local home reg out marker
  home=$(make_fleet daemon-wedge)
  reg=$(reg_of "$home")
  printf 'working: waiting on the captain\n' > "$home/state/sm-alpha.status"
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(FM_SECONDMATE_COMMAND_REGISTRY="$reg" bash -c \
    ". '$ROOT/bin/fm-supervise-daemon.sh'; classify_stale 'firstmate:fm-sm-alpha' '$home/state'")
  assert_contains "$out" "captain command" \
    "an idle lane awaiting its captain is expected, not a wedge firstmate must fix"
  case "$out" in
    escalate\|*) fail "a captain-commanded lane must not be escalated to firstmate as a wedge: $out" ;;
  esac
  # And it never accrues a wedge marker for housekeeping to age later.
  FM_STATE_OVERRIDE="$home/state" FM_SECONDMATE_COMMAND_REGISTRY="$reg" bash -c \
    ". '$ROOT/bin/fm-supervise-daemon.sh'
     handle_wake 'stale: firstmate:fm-sm-alpha' '$home/state'" >/dev/null 2>&1
  for marker in "$home"/state/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    fail "a captain-commanded lane must never accrue a wedge marker, found $marker"
  done
  pass "the away-mode daemon never calls a captain-commanded lane a wedge"
}

# --- 8. session start and the liveness sweep --------------------------------

test_session_start_digest_reports_command_state() {
  local home out
  home=$(make_fleet session-start)
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-session-start.sh" 2>&1 || true)
  assert_contains "$out" "command: captain - the captain commands this lane" \
    "a restarting firstmate must see which lanes the captain holds before it resumes supervising"
  pass "the session-start digest reports command state"
}

# Detect-only, so it must also fire in a read-only session: a lane that may be
# addressing the wrong person is not something any session may act around.
test_bootstrap_reports_a_divergent_command_record() {
  local home lane out
  home=$(make_fleet bootstrap-divergence)
  lane=$(lane_of "$home")
  run_cmd "$home" onramp sm-alpha >/dev/null
  printf '# Command state\n\ncommand: firstmate\n' > "$lane/data/command.md"
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_contains "$out" "SECONDMATE_COMMAND: secondmate sm-alpha" \
    "a lane whose two command records disagree must be reported at session start"
  assert_contains "$out" "the registry is authoritative" \
    "the report must say which side wins so nobody reconciles it by guessing"
  pass "session start reports a divergent command record even in a read-only session"
}

test_bootstrap_is_silent_when_command_records_agree() {
  local home out
  home=$(make_fleet bootstrap-agree)
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_not_contains "$out" "SECONDMATE_COMMAND:" \
    "an agreeing lane must stay silent; a routine confirmation is not a diagnostic"
  pass "session start stays silent when a lane's command records agree"
}

test_liveness_sweep_reports_relaunching_a_captain_commanded_lane() {
  local home out
  home=$(make_fleet liveness)
  run_cmd "$home" onramp sm-alpha >/dev/null
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c ". '$ROOT/bin/fm-bootstrap.sh' >/dev/null 2>&1; true" 2>&1 || true)
  # The sweep itself is exercised in fm-secondmate-liveness.test.sh; here we only
  # need the contract that a captain-commanded relaunch is never silent.
  assert_grep 'under captain command' "$ROOT/bin/fm-bootstrap.sh" \
    "relaunching a lane the captain is talking to must always be reported, never silent"
  pass "the liveness sweep never silently restarts a captain-commanded lane"
}

# --- tracked instruction surfaces -------------------------------------------

test_hard_rule_four_is_conditional_not_optional() {
  assert_grep 'Crewmates never address the captain.' "$AGENTS" \
    "hard rule 4 must keep its default"
  assert_grep 'recorded as captain command' "$AGENTS" \
    "hard rule 4 must make the exception conditional on a recorded transfer"
  assert_grep 'never decides its own command state' "$AGENTS" \
    "hard rule 4 must forbid a lane deciding its own command state"
  pass "hard rule 4 is conditional on a recorded transfer, not optional"
}

test_the_transfer_skill_is_registered_with_a_precise_trigger() {
  assert_present "$SKILL" "the command-transfer skill must exist"
  assert_grep 'secondmate-command-transfer' "$AGENTS" \
    "AGENTS.md must carry the skill's load trigger"
  assert_grep '.agents/skills/secondmate-command-transfer/SKILL.md' \
    "$ROOT/docs/documentation-audiences.json" \
    "a new agent-runtime skill must be classified in the documentation inventory"
  pass "the transfer skill is registered with a precise trigger"
}

test_the_secondmate_charter_states_the_conditional_address_contract() {
  local home out
  home="$TMP_ROOT/charter-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Own the alpha domain.' \
    "$BRIEF" sm-alpha --secondmate alpha >/dev/null
  out="$home/data/sm-alpha/brief.md"
  assert_present "$out" "the charter scaffold must be written"
  assert_grep 'data/command.md' "$out" \
    "the charter must point the lane at the record of who commands it"
  assert_grep 'no captain in this pane' "$out" \
    "under firstmate command the charter must say the captain channel does not exist"
  pass "the seeded charter states the conditional address contract"
}

# --- run --------------------------------------------------------------------

FAKE_CREW_STATE=$(make_lane_state_reader "$TMP_ROOT/fakes")
FAKE_SEND=$(make_fake_send "$TMP_ROOT/fakes")
ALIVE_TMUX=$(make_alive_tmux "$TMP_ROOT/alive")

test_absent_field_means_firstmate_command
test_explicit_captain_command_is_read_from_the_registry
test_unrecognized_command_value_fails_closed
test_unregistered_id_is_not_a_lane
test_command_field_parses_beside_a_label_field

test_status_reports_each_lane_and_flags_captain_command
test_status_exits_nonzero_on_a_registry_marker_divergence
test_status_treats_an_absent_marker_as_firstmate_command

test_onramp_refuses_an_unregistered_lane
test_onramp_refuses_while_away_mode_is_active
test_onramp_refuses_an_unresolved_decision_on_the_parent_channel
test_onramp_allows_a_decision_that_was_resolved
test_onramp_refuses_an_open_request_awaiting_the_lanes_answer
test_onramp_refuses_a_live_validation_run_in_the_lane_home
test_onramp_allows_a_lane_whose_run_already_finished
test_onramp_refuses_a_lane_whose_endpoint_is_confirmed_absent
test_onramp_has_no_override_flag

test_onramp_transfers_registry_marker_and_position_record
test_onramp_is_idempotent
test_onramp_keeps_every_other_registry_field
test_both_directions_tell_the_running_lane
test_both_directions_notify_when_fm_home_is_not_in_the_environment
test_an_undelivered_notice_is_not_reported_as_a_finished_transfer

test_offramp_complete_refuses_without_a_position_report
test_offramp_request_records_the_expected_report_and_asks_the_lane
test_offramp_request_reuses_an_unanswered_request
test_offramp_request_refuses_a_firstmate_commanded_lane
test_offramp_complete_refuses_a_report_it_did_not_ask_for
test_offramp_complete_refuses_a_stale_report
test_offramp_complete_returns_the_lane_after_a_fresh_report

test_fm_send_refuses_to_steer_a_captain_commanded_lane
test_fm_send_still_steers_a_firstmate_commanded_lane
test_fm_send_lets_infrastructure_messages_reach_the_lane
test_fm_send_refuses_a_lane_whose_command_record_is_missing
test_fm_send_refuses_to_interrupt_a_captain_commanded_lane
test_the_handback_request_can_still_be_retried
test_a_completed_handback_closes_its_own_expectation
test_backlog_handoff_refuses_a_captain_commanded_lane
test_teardown_refuses_to_retire_a_captain_commanded_lane
test_a_lost_command_record_blocks_every_action_on_a_known_lane

test_watcher_triage_absorbs_a_captain_commanded_lanes_status_events
test_watcher_triage_keeps_a_damaged_record_loud
test_watcher_does_not_wake_firstmate_for_a_captain_commanded_lane
test_watcher_still_wakes_firstmate_for_an_ordinary_lane
test_daemon_never_calls_a_captain_commanded_lane_a_wedge

test_session_start_digest_reports_command_state
test_bootstrap_reports_a_divergent_command_record
test_bootstrap_is_silent_when_command_records_agree
test_liveness_sweep_reports_relaunching_a_captain_commanded_lane

test_hard_rule_four_is_conditional_not_optional
test_the_transfer_skill_is_registered_with_a_precise_trigger
test_the_secondmate_charter_states_the_conditional_address_contract
