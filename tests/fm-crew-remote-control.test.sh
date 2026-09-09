#!/usr/bin/env bash
# Behavior tests for Remote Control on crewmate and scout launches, which lets
# the operator drive a claude worker from claude.ai/code and the phone app
# instead of only the firstmate pane.
#
# The contract under test:
#   1. It is ON BY DEFAULT. With config/crew-remote-control absent, a claude
#      crewmate and a claude scout both launch with
#      `--remote-control <session-name>`, because a worker the operator cannot
#      reach from a phone is the exception rather than the rule.
#   2. config/crew-remote-control=off is the opt-out, and the only value that
#      suppresses the flag. An opted-out launch is asserted as a whole-line
#      equality against the canonical no-Remote-Control launch, because the
#      requirement there is that nothing changes rather than that one substring
#      is absent. An unrecognized value warns and falls back to the default.
#   3. Every LAUNCH gets its own session. The name is
#      <task-id>.<home-basename>.<launch-token>, where the launch token is
#      derived from this spawn's own spawn_gen incarnation token, so two launches
#      never share a name: not two homes spawning one task id, not two tasks in
#      one home, and not a relaunch of the same task (which
#      tests/fm-control-relaunch.test.sh owns end to end). The task id and the
#      basename are capped, bounding the whole name at 52 characters. The name is
#      passed EXPLICITLY and before the positional brief prompt, so the
#      optional-argument form of that flag cannot swallow the brief.
#   4. Only claude. Every other verified adapter launches with no flag at all,
#      and a harness that cannot do Remote Control is not an error. Covered for
#      codex, opencode, grok, pi, cursor, and gemini; kimi and muse are left
#      out because both need a real installed binary to reach their launch step. This
#      direction is asserted with the knob ABSENT, which is the reachable
#      default, so "no flag here" is proven where it actually matters.
#   5. Only crewmates and scouts. A secondmate launch, and a raw launch command,
#      never carry the flag either.
#   6. The flag is only typed at a claude that advertises it. claude refuses an
#      unknown option outright, so the verdict comes from the installed binary's
#      own --help and every failure direction - help without the option, a
#      non-zero exit, empty output, an unrunnable binary - launches without the
#      flag instead of failing the spawn. Only a verdict ABOUT THE BINARY is
#      cached (advertised, or ran and did not advertise), keyed to the binary's
#      identity so an upgrade or downgrade re-probes; a probe that could not
#      complete is never cached, so one loaded moment cannot disable Remote
#      Control on that home indefinitely. The bound comes from
#      bin/fm-timeout-lib.sh, so the probe works on a host with no timeout
#      binary.
#
# The `claude` on PATH here is always a stub, so the probe's verdict is fixture
# state rather than whatever version this machine has installed. The real
# installed claude is covered by the opt-in live guard
# tests/fm-crew-remote-control-live-e2e.test.sh.
#
# These drive the REAL fm-spawn against a fake tmux that captures the literal
# `tmux send-keys -l` launch command, the same technique as
# tests/fm-spawn-dispatch-profile.test.sh, so the assertions pin the command
# firstmate would run without starting any real harness.
#
# The live half of this contract - that claude actually accepts the flag
# alongside the positional brief, keeps an ordinary steerable TUI, and keeps
# firing the worktree hooks supervision reads - is empirical and lives in
# docs/verification/remote-control.md.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-remote-control)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  # Pi probes its own --help for --tui-mode and Cursor probes its live model
  # catalog before launching, so both need a responding stub to reach the launch
  # step at all. Same shape as tests/fm-spawn-dispatch-profile.test.sh.
  # A `timeout` stand-in, because a fixture must not depend on coreutils being
  # installed. It accepts the option forms its real callers pass - bin/fm-spawn's
  # own harness probes send `timeout <seconds> <command>`, and
  # bin/fm-timeout-lib.sh sends `timeout -k 1 <seconds> <command>` - then runs the
  # command unbounded, which is all stubbed probes need. A case that needs a REAL
  # bound sets FM_TIMEOUT_MECHANISM_OVERRIDE=bash instead.
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k|--kill-after) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  printf '%b\n' "Available models\ncursor-grok-4.5-high - Grok 4.5 High"
fi
exit 0
SH
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent" "$fakebin/pi"
  write_fake_claude "$fakebin" supports
  printf '%s\n' "$fakebin"
}

# write_fake_claude <fakebin> <mode>: the claude the capability probe sees.
# Every mode answers --help the way some real or broken claude would. The mode is
# BAKED into the stub, so two modes are two different binaries with different
# fingerprints, and it can also be overridden per spawn with FM_FAKE_CLAUDE_MODE,
# which changes behavior WITHOUT changing the stub's bytes - that is how a case
# proves what the verdict cache does and does not remember.
# Every mode records the probe in FM_FAKE_CLAUDE_PROBE_LOG when that file is set,
# so a case can assert how many times the probe actually ran.
#   supports     help advertises `--remote-control [name]`
#   no-flag      help of a claude predating Remote Control
#   prefix-only  help advertising ONLY --remote-control-session-name-prefix
#   exit-nonzero help text present but the command fails
#   empty        exits 0 and prints nothing
#   hang         never returns, so the probe's bound is what ends it
#   unrunnable   executable, but its interpreter does not exist
write_fake_claude() {
  local fakebin=$1 mode=$2
  if [ "$mode" = unrunnable ]; then
    printf '%s\n' '#!/nonexistent-interpreter-for-fm-tests' 'exit 0' > "$fakebin/claude"
    chmod +x "$fakebin/claude"
    return 0
  fi
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
set -u
mode=\${FM_FAKE_CLAUDE_MODE:-}
[ -n "\$mode" ] || mode=$mode
[ "\${1:-}" = --help ] || exit 0
[ -z "\${FM_FAKE_CLAUDE_PROBE_LOG:-}" ] || printf 'help\n' >> "\$FM_FAKE_CLAUDE_PROBE_LOG"
case "\$mode" in
  supports)
    printf '%s\n' 'Usage: claude [options] [prompt]' \
      '  --remote-control [name]     Start an interactive session with Remote Control enabled (optionally named)' \
      '  --remote-control-session-name-prefix <prefix>  Prefix for auto-generated names'
    ;;
  no-flag)
    printf '%s\n' 'Usage: claude [options] [prompt]' \
      '  --dangerously-skip-permissions   Bypass all permission checks' \
      '  --model <model>   Model for the session'
    ;;
  prefix-only)
    printf '%s\n' 'Usage: claude [options] [prompt]' \
      '  --remote-control-session-name-prefix <prefix>  Prefix for auto-generated Remote Control session names'
    ;;
  exit-nonzero)
    printf '%s\n' '  --remote-control [name]   Start an interactive session with Remote Control enabled'
    exit 3
    ;;
  empty) : ;;
  hang) sleep 30 ;;
  *) printf 'unknown fake claude mode: %s\n' "\$mode" >&2; exit 9 ;;
esac
exit 0
SH
  chmod +x "$fakebin/claude"
}

# make_spawn_case <name> <harness> <remote-control-file-content> <task-id...>
# A literal '-' for the knob content leaves config/crew-remote-control absent,
# which is the default-on path.
make_spawn_case() {
  local name=$1 harness=$2 knob=$3 case_dir home proj wt fakebin launchlog id
  shift 3
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/${FM_TEST_CASE_HOME_BASENAME:-home}"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  [ "$knob" = '-' ] || printf '%s\n' "$knob" > "$home/config/crew-remote-control"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR and PROJ_DIR are part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOFR
$1
EOFR
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # empty rather than leaking the developer's environment into the launch
  # assertions below.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_CLAUDE_PROBE_LOG="${FM_FAKE_CLAUDE_PROBE_LOG:-}" \
    FM_FAKE_CLAUDE_MODE="${FM_FAKE_CLAUDE_MODE:-}" \
    FM_CLAUDE_PROBE_TIMEOUT="${FM_CLAUDE_PROBE_TIMEOUT:-}" \
    FM_TIMEOUT_MECHANISM_OVERRIDE="${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); this
# suite is about the Remote Control flag, so it passes a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# The canonical claude launch command, with the Remote Control flag spliced in at
# exactly the point bin/fm-spawn.sh's claude template places it. Everything
# around that flag - the prompt-suggestion and feedback controls, the permission
# flag, and the positionally delivered brief - belongs to that template rather
# than to this feature, so it is written once here and both the with-flag and
# without-flag expectations are built from it.
# The brief file the launch line reads is the spawn's, not this feature's:
# every ship and scout spawn is delivered the rendered launch-brief.md
# (bin/fm-spawn.sh), so the basename is shared rather than named per kind.
claude_launch_line() {  # <home> <task-id> <flag-including-trailing-space-or-empty> [brief-basename]
  local brief=${4:-launch-brief.md}
  printf '%s' "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' $3\"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$1/data/$2/$brief')\""
}

# What firstmate typed before this feature existed, and what a home that writes
# "off" must keep getting.
claude_launch_without_flag() {  # <home> <task-id> [brief-basename]
  claude_launch_line "$1" "$2" '' "${3:-}"
}

# The name shape the contract in docs/configuration.md promises, derived here
# independently of the implementation: the task id capped at 32, the resolved
# home's sanitized basename capped at 12, and six hex characters of the sha256 of
# THIS launch's spawn_gen. The caps are part of the contract because they are
# what bound the whole name at 52 characters.
# spawn_gen is read back from state/<id>.meta, the launch record fm-spawn
# persists for exactly this purpose (AGENTS.md section 2), which is what ties the
# assertion to the incarnation that just launched rather than to the task.
RC_TASK_ID_MAX=32
RC_HOME_BASENAME_MAX=12
RC_NAME_MAX=52

recorded_spawn_gen() {  # <home> <task-id>
  local gen
  gen=$(sed -n 's/^spawn_gen=//p' "$1/state/$2.meta" 2>/dev/null | tail -1) || return 1
  [ -n "$gen" ] || return 1
  printf '%s' "$gen"
}

expected_rc_name() {  # <home> <task-id>
  local home=$1 id=$2 resolved base gen token
  resolved=$(CDPATH='' cd -- "$home" && pwd -P) || return 1
  base=${resolved##*/}
  base=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')
  gen=$(recorded_spawn_gen "$home" "$id") || return 1
  if command -v shasum >/dev/null 2>&1; then
    token=$(printf '%s' "$gen" | shasum -a 256 | awk '{print substr($1,1,6)}')
  else
    token=$(printf '%s' "$gen" | sha256sum | awk '{print substr($1,1,6)}')
  fi
  [ -n "$token" ] || return 1
  printf '%s.%s.%s' "${id:0:RC_TASK_ID_MAX}" "${base:0:RC_HOME_BASENAME_MAX}" "$token"
}

claude_launch_with_flag() {  # <home> <task-id> [brief-basename]
  claude_launch_line "$1" "$2" "--remote-control '$(expected_rc_name "$1" "$2")' " "${3:-}"
}

# Extract the Remote Control session name firstmate actually typed.
launched_rc_name() {  # <launch-command>
  printf '%s' "$1" | sed -n "s/.*--remote-control '\([^']*\)'.*/\1/p"
}

# --- 1. the default: absent knob means Remote Control is on ------------------

test_default_launches_claude_with_remote_control() {
  local rec id out status launch expected
  id=rc-default-a1
  rec=$(make_spawn_case rc-default claude - "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn on the default should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  expected=$(claude_launch_with_flag "$HOME_DIR" "$id")
  [ "$launch" = "$expected" ] \
    || fail "with no config/crew-remote-control a claude crewmate must launch with Remote Control on"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "default: a claude crewmate launches with --remote-control and a per-launch name"
}

test_default_launches_a_scout_with_remote_control() {
  local rec id out status launch expected
  id=rc-default-scout-a2
  rec=$(make_spawn_case rc-default-scout claude - "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "claude scout spawn on the default should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  expected=$(claude_launch_with_flag "$HOME_DIR" "$id")
  [ "$launch" = "$expected" ] \
    || fail "a claude SCOUT must be reachable by default too"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "default: a claude scout launches with Remote Control the same way"
}

test_default_names_the_session_before_the_positional_brief() {
  local rec id launch flag_at brief_at out
  id=rc-order-a3
  rec=$(make_spawn_case rc-order claude - "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn on the default should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")

  # `--remote-control` takes an OPTIONAL value, so a bare flag would consume
  # whatever followed it. The explicit name must therefore sit between the flag
  # and the positional brief prompt, which is what keeps the brief positional.
  flag_at=${launch%%--remote-control*}
  brief_at=${launch%%encode launch-brief*}
  [ "${#flag_at}" -lt "${#brief_at}" ] \
    || fail "--remote-control must precede the positional brief prompt"$'\n'"actual: $launch"
  assert_contains "$launch" "--remote-control '$(expected_rc_name "$HOME_DIR" "$id")' \"" \
    "the session name must be consumed by the flag, immediately before the positional prompt"
  pass "default: an explicit session name separates the flag from the positional brief"
}

test_default_composes_with_model_and_effort() {
  local rec id out status launch
  id=rc-profile-a4
  rec=$(make_spawn_case rc-profile claude - "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model haiku --effort low)
  status=$?
  expect_code 0 "$status" "claude spawn with a profile should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--remote-control '$(expected_rc_name "$HOME_DIR" "$id")' --model 'haiku' --effort 'low' \"" \
    "the Remote Control flag must compose with the model and effort axes without displacing the prompt"
  pass "default: the flag composes with --model and --effort"
}

# --- 2. the session name is qualified by the home ---------------------------

# Task ids are unique only within one home's task set, and the knob is inherited
# into secondmate homes, so the same task id spawned from two homes must not
# produce one label in the operator's claude.ai session list.
test_session_name_is_qualified_by_the_home() {
  local rec_a rec_b id home_a home_b name_a name_b out
  id=rc-shared-id-b1

  rec_a=$(make_spawn_case rc-home-a claude - "$id")
  read_case_record "$rec_a"
  home_a=$HOME_DIR
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 $? "the first home's spawn should succeed"$'\n'"$out"
  name_a=$(launched_rc_name "$(cat "$LAUNCH_LOG")")

  rec_b=$(make_spawn_case rc-home-b claude - "$id")
  read_case_record "$rec_b"
  home_b=$HOME_DIR
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 $? "the second home's spawn should succeed"$'\n'"$out"
  name_b=$(launched_rc_name "$(cat "$LAUNCH_LOG")")

  [ -n "$name_a" ] && [ -n "$name_b" ] \
    || fail "both spawns must carry a Remote Control session name (a=$name_a b=$name_b)"
  [ "$name_a" != "$name_b" ] \
    || fail "the same task id in two different homes must not produce one session name: $name_a"
  case "$name_a" in "$id".*) ;; *) fail "the task id must lead the session name: $name_a" ;; esac
  case "$name_b" in "$id".*) ;; *) fail "the task id must lead the session name: $name_b" ;; esac
  [ "$name_a" = "$(expected_rc_name "$home_a" "$id")" ] \
    || fail "home A's session name must be <task-id>.<home-basename>.<launch-token>"$'\n'"expected: $(expected_rc_name "$home_a" "$id")"$'\n'"actual:   $name_a"
  [ "$name_b" = "$(expected_rc_name "$home_b" "$id")" ] \
    || fail "home B's session name must be <task-id>.<home-basename>.<launch-token>"$'\n'"expected: $(expected_rc_name "$home_b" "$id")"$'\n'"actual:   $name_b"
  pass "the session name is qualified by the home, so one task id in two homes yields two names"
}

# Every launch is its own session, so what the operator sees in the session list
# is the worker running now. Two tasks in one home therefore share only the home
# part of the name and differ in the launch token, and each token is the digest of
# that launch's own recorded spawn_gen. The same-task-id-across-a-relaunch case
# is owned by tests/fm-control-relaunch.test.sh, which has the relaunch fixture.
test_every_launch_gets_a_distinct_session_name() {
  local rec id_a id_b name_a name_b out
  id_a=rc-samehome-b2
  id_b=rc-samehome-b3
  rec=$(make_spawn_case rc-samehome claude - "$id_a" "$id_b")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR")
  expect_code 0 $? "the first task's spawn should succeed"$'\n'"$out"
  name_a=$(launched_rc_name "$(cat "$LAUNCH_LOG")")

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR")
  expect_code 0 $? "the second task's spawn should succeed"$'\n'"$out"
  name_b=$(launched_rc_name "$(cat "$LAUNCH_LOG")")

  [ -n "$name_a" ] && [ -n "$name_b" ] \
    || fail "both spawns must carry a Remote Control session name (a=$name_a b=$name_b)"
  [ "$name_a" = "$(expected_rc_name "$HOME_DIR" "$id_a")" ] \
    || fail "the launch token must be the digest of that launch's recorded spawn_gen"$'\n'"expected: $(expected_rc_name "$HOME_DIR" "$id_a")"$'\n'"actual:   $name_a"
  [ "$name_b" = "$(expected_rc_name "$HOME_DIR" "$id_b")" ] \
    || fail "the launch token must be the digest of that launch's recorded spawn_gen"$'\n'"expected: $(expected_rc_name "$HOME_DIR" "$id_b")"$'\n'"actual:   $name_b"
  [ "${name_a%.*}" != "${name_b%.*}" ] || [ "${name_a##*.}" != "${name_b##*.}" ] \
    || fail "two launches in one home must not share a launch token: $name_a"
  [ "${name_a#*.}" != "${name_b#*.}" ] \
    || fail "the launch token must differ between two launches in one home: ${name_a#*.}"
  pass "every launch gets its own session name, tied to that launch's spawn_gen"
}

# The caps are what keep the emitted name bounded at 52 characters. Both are
# exercised, because an over-long task id and an over-long home basename truncate
# independently.
#   <case>^<task-id>^<home-basename>
test_the_name_caps_hold() {
  local case_name id home_base rec out launch name n=0
  while IFS='^' read -r case_name id home_base; do
    [ -n "$case_name" ] || continue
    n=$((n + 1))
    FM_TEST_CASE_HOME_BASENAME="$home_base"
    rec=$(make_spawn_case "rc-cap-$case_name" claude - "$id")
    unset FM_TEST_CASE_HOME_BASENAME
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    expect_code 0 $? "the $case_name case should still spawn"$'\n'"$out"

    launch=$(cat "$LAUNCH_LOG")
    name=$(launched_rc_name "$launch")
    [ "$name" = "$(expected_rc_name "$HOME_DIR" "$id")" ] \
      || fail "$case_name: the emitted name must match the capped shape"$'\n'"expected: $(expected_rc_name "$HOME_DIR" "$id")"$'\n'"actual:   $name"
    [ "${#name}" -le "$RC_NAME_MAX" ] \
      || fail "$case_name: the emitted name must stay within $RC_NAME_MAX characters, got ${#name} in $name"
  done <<'ROWS'
long-task-id^rc-cap-task-id-that-runs-well-past-the-thirty-two-character-cap^firstmate
long-home^rc-cap-b5^firstmate-secondmate-platform-infra-very-long-home-name
ROWS
  [ "$n" -eq 2 ] || fail "expected 2 cap rows, ran $n"
  pass "the task-id and home-basename caps hold, so the emitted name stays bounded ($n cases)"
}

# --- 3. "off" is the opt-out, and the only value that disables it ------------

test_off_leaves_the_claude_launch_unchanged() {
  local rec id out status launch expected
  id=rc-off-c1
  rec=$(make_spawn_case rc-off claude off "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with the knob off should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  expected=$(claude_launch_without_flag "$HOME_DIR" "$id")
  [ "$launch" = "$expected" ] \
    || fail "config/crew-remote-control=off must leave the claude launch byte-identical to the pre-feature launch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "off: the claude launch carries no Remote Control flag and is unchanged"
}

test_off_leaves_a_scout_launch_unchanged() {
  local rec id out status launch
  id=rc-off-scout-c2
  rec=$(make_spawn_case rc-off-scout claude off "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "claude scout spawn with the knob off should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id")" ] \
    || fail "off must leave a claude SCOUT launch byte-identical too"$'\n'"actual: $launch"
  pass "off: a claude scout launch is unchanged"
}

# The value is read whitespace-stripped and case-folded, the convention the other
# scalar config items already use, so content the operator cannot see must not
# decide the verdict.
test_off_is_read_case_and_whitespace_insensitively() {
  local label content id rec out launch n=0
  while IFS='^' read -r label content id; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_spawn_case "rc-off-$label" claude "$content" "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    expect_code 0 $? "claude spawn with crew-remote-control=$label should succeed"$'\n'"$out"

    launch=$(cat "$LAUNCH_LOG")
    [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id")" ] \
      || fail "config/crew-remote-control=$label must disable Remote Control"$'\n'"actual: $launch"
  done <<'ROWS'
upper^OFF^rc-off-upper-c3
padded^  off  ^rc-off-padded-c4
ROWS
  [ "$n" -eq 2 ] || fail "expected 2 off-spelling rows, ran $n"
  pass "off: case and surrounding whitespace do not change the verdict ($n spellings)"
}

# An explicit "on" and the historical empty-file presence form both mean on, so
# no home that deliberately enabled this can lose it.
test_enabling_values_keep_remote_control_on() {
  local label content id rec out launch n=0
  while IFS='^' read -r label content id; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_spawn_case "rc-on-$label" claude "$content" "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    expect_code 0 $? "claude spawn with crew-remote-control=$label should succeed"$'\n'"$out"

    launch=$(cat "$LAUNCH_LOG")
    [ "$launch" = "$(claude_launch_with_flag "$HOME_DIR" "$id")" ] \
      || fail "config/crew-remote-control=$label must leave Remote Control on"$'\n'"actual: $launch"
  done <<'ROWS'
explicit^on^rc-on-explicit-d1
upper^ON^rc-on-upper-d2
empty^^rc-on-empty-d3
ROWS
  [ "$n" -eq 3 ] || fail "expected 3 enabling-value rows, ran $n"
  pass "on: an explicit, upper-case, or empty value all keep Remote Control on ($n values)"
}

# A typo must be visible rather than silently deciding anything, and it must not
# fail the spawn over a launch flag.
test_unrecognized_value_warns_and_falls_back_to_the_default() {
  local rec id out status launch
  id=rc-junk-d4
  rec=$(make_spawn_case rc-junk claude 'onn' "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an unrecognized knob value must never fail a spawn"$'\n'"$out"

  assert_contains "$out" 'config/crew-remote-control: unrecognized value "onn"' \
    "the warning must name the file and the offending value"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_with_flag "$HOME_DIR" "$id")" ] \
    || fail "an unrecognized value must fall back to the default (on)"$'\n'"actual: $launch"
  pass "unrecognized value: warns naming the file and the value, and still launches on the default"
}

# --- 3b. the flag is only typed at a claude that advertises it ---------------

# claude refuses an unknown option outright, so a claude predating Remote
# Control must be launched WITHOUT the flag rather than fail. This is the whole
# reason a probe exists, and it is asserted as a whole-line equality because the
# requirement is that such a home launches exactly what it launched before this
# feature existed.
test_claude_without_the_option_launches_unchanged() {
  local rec id out status launch expected
  id=rc-noflag-f1
  rec=$(make_spawn_case rc-noflag claude - "$id")
  read_case_record "$rec"
  write_fake_claude "$FAKEBIN_DIR" no-flag

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a claude without Remote Control must still spawn"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  expected=$(claude_launch_without_flag "$HOME_DIR" "$id")
  [ "$launch" = "$expected" ] \
    || fail "a claude whose --help does not advertise --remote-control must launch unchanged"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "probe: a claude without the option launches byte-identically to the pre-feature launch"
}

# The two options share a prefix, so a help text advertising ONLY
# --remote-control-session-name-prefix must not be read as support. This drives
# the signal apart from the one above rather than trusting a loose substring.
test_prefix_option_alone_does_not_enable_the_flag() {
  local rec id out launch
  id=rc-prefixonly-f2
  rec=$(make_spawn_case rc-prefixonly claude - "$id")
  read_case_record "$rec"
  write_fake_claude "$FAKEBIN_DIR" prefix-only

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 $? "a prefix-only claude must still spawn"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id")" ] \
    || fail "only --remote-control itself may enable the flag, not its session-name-prefix sibling"$'\n'"actual: $launch"
  pass "probe: --remote-control-session-name-prefix alone is not read as support"
}

# Every way the probe itself can fail must land on a working worker, never on a
# failed spawn.
#   <mode>^<task-id>
test_a_failed_probe_launches_unchanged_and_still_spawns() {
  local mode id rec out status launch n=0
  while IFS='^' read -r mode id; do
    [ -n "$mode" ] || continue
    n=$((n + 1))
    rec=$(make_spawn_case "rc-probe-$mode" claude - "$id")
    read_case_record "$rec"
    write_fake_claude "$FAKEBIN_DIR" "$mode"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "a $mode probe must never fail the spawn"$'\n'"$out"

    launch=$(cat "$LAUNCH_LOG")
    [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id")" ] \
      || fail "a $mode probe must launch without the flag"$'\n'"actual: $launch"
  done <<'ROWS'
exit-nonzero^rc-probe-exit-f3
empty^rc-probe-empty-f4
unrunnable^rc-probe-unrunnable-f5
ROWS
  [ "$n" -eq 3 ] || fail "expected 3 probe-failure rows, ran $n"
  pass "probe: a failing probe launches without the flag and never fails a spawn ($n failure modes)"
}

# The verdict is cached against the binary's identity: a second spawn in the same
# home does not re-probe, and replacing the binary re-probes rather than serving
# a stale answer. A cache that outlived its binary would suppress the flag
# forever on the next claude upgrade, which is the failure this pins.
test_probe_verdict_is_cached_but_follows_the_binary() {
  local rec id_a id_b id_c launch probes
  id_a=rc-cache-g1
  id_b=rc-cache-g2
  id_c=rc-cache-g3
  rec=$(make_spawn_case rc-cache claude - "$id_a" "$id_b" "$id_c")
  read_case_record "$rec"
  FM_FAKE_CLAUDE_PROBE_LOG="$CASE_DIR/probe.log"
  : > "$FM_FAKE_CLAUDE_PROBE_LOG"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--remote-control '$(expected_rc_name "$HOME_DIR" "$id_a")'" \
    "the first spawn should have probed and enabled Remote Control"
  probes=$(grep -c . "$FM_FAKE_CLAUDE_PROBE_LOG")
  [ "$probes" -eq 1 ] || fail "the first spawn should probe exactly once, probed $probes times"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--remote-control '$(expected_rc_name "$HOME_DIR" "$id_b")'" \
    "the cached verdict should still enable Remote Control"
  probes=$(grep -c . "$FM_FAKE_CLAUDE_PROBE_LOG")
  [ "$probes" -eq 1 ] || fail "a second spawn on the same binary must reuse the cached verdict, probed $probes times"

  # Same path, different binary: the fingerprint changes, so the verdict must be
  # re-derived rather than served from the cache.
  write_fake_claude "$FAKEBIN_DIR" no-flag
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_c" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id_c")" ] \
    || fail "replacing claude with one that lacks the option must drop the flag"$'\n'"actual: $launch"
  probes=$(grep -c . "$FM_FAKE_CLAUDE_PROBE_LOG")
  [ "$probes" -eq 2 ] || fail "replacing the binary must re-probe, probed $probes times"
  unset FM_FAKE_CLAUDE_PROBE_LOG
  pass "probe: the verdict is cached per binary and re-derived when the binary changes"
}

# The bound comes from bin/fm-timeout-lib.sh, the declared owner of bounded
# execution, rather than from a timeout invocation of the probe's own. That
# matters on a host with neither timeout nor gtimeout - stock macOS without
# coreutils - where a probe that insisted on those binaries would report every
# claude unsupported and silently strip the flag from every launch.
# This case reproduces such a host without needing one: the fixture's `timeout`
# is replaced by one that cannot run anything, and the library's own documented
# FM_TIMEOUT_MECHANISM_OVERRIDE selects its dependency-free path. A probe that
# reached for `timeout` itself would come back empty-handed here.
test_the_probe_uses_the_shared_bounded_runner() {
  local rec id out launch
  id=rc-nobound-g4
  rec=$(make_spawn_case rc-nobound claude - "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/timeout" <<'SH'
#!/usr/bin/env bash
echo "timeout: this host has no usable timeout binary" >&2
exit 127
SH
  chmod +x "$FAKEBIN_DIR/timeout"

  out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 $? "the spawn should succeed with no usable timeout binary"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_with_flag "$HOME_DIR" "$id")" ] \
    || fail "the probe must bound itself through fm-timeout-lib.sh, so a host with no timeout binary still enables Remote Control"$'\n'"actual: $launch"
  pass "probe: the bound comes from the shared runner, so no timeout binary is required"
}

# A probe that could not complete says nothing about the binary, so it must not be
# remembered. Otherwise one loaded moment would disable Remote Control on that
# home until the binary itself changed. The stub's BYTES stay identical across
# both phases here, so the fingerprint is unchanged and a cache hit would be
# visible as a missing flag and an unchanged probe count.
test_a_transient_probe_failure_is_not_cached() {
  local rec id_a id_b launch probes
  id_a=rc-transient-g5
  id_b=rc-transient-g6
  rec=$(make_spawn_case rc-transient claude - "$id_a" "$id_b")
  read_case_record "$rec"
  FM_FAKE_CLAUDE_PROBE_LOG="$CASE_DIR/probe.log"
  : > "$FM_FAKE_CLAUDE_PROBE_LOG"

  FM_FAKE_CLAUDE_MODE=exit-nonzero \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id_a")" ] \
    || fail "a failed probe must launch without the flag"$'\n'"actual: $launch"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_with_flag "$HOME_DIR" "$id_b")" ] \
    || fail "the next spawn must re-probe rather than inherit a transient failure"$'\n'"actual: $launch"
  probes=$(grep -c . "$FM_FAKE_CLAUDE_PROBE_LOG")
  [ "$probes" -eq 2 ] || fail "both spawns must probe when the first probe failed, probed $probes times"
  unset FM_FAKE_CLAUDE_PROBE_LOG
  pass "probe: a probe that could not complete is never cached"
}

# The bound itself is a transient failure: it ends the probe without learning
# anything about the binary, so it must not be remembered either.
test_a_probe_that_hits_the_bound_is_not_cached() {
  local rec id_a id_b out launch probes
  id_a=rc-bound-g7
  id_b=rc-bound-g8
  rec=$(make_spawn_case rc-bound claude - "$id_a" "$id_b")
  read_case_record "$rec"
  FM_FAKE_CLAUDE_PROBE_LOG="$CASE_DIR/probe.log"
  : > "$FM_FAKE_CLAUDE_PROBE_LOG"

  out=$(FM_FAKE_CLAUDE_MODE=hang FM_CLAUDE_PROBE_TIMEOUT=1 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR")
  expect_code 0 $? "a claude whose --help never returns must not fail the spawn"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id_a")" ] \
    || fail "a probe that hit its bound must launch without the flag"$'\n'"actual: $launch"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_with_flag "$HOME_DIR" "$id_b")" ] \
    || fail "a hit bound must not leave a durable unsupported verdict behind"$'\n'"actual: $launch"
  probes=$(grep -c . "$FM_FAKE_CLAUDE_PROBE_LOG")
  [ "$probes" -eq 2 ] || fail "the second spawn must re-probe after a bounded-out probe, probed $probes times"
  unset FM_FAKE_CLAUDE_PROBE_LOG
  pass "probe: hitting the bound suppresses the flag for that spawn only"
}

# The other half of the same rule: a verdict that IS about the binary is cached,
# so the flag decision does not pay for a probe on every spawn. The stub's bytes
# are again identical across both phases, and here the cached answer must win over
# the changed behavior.
test_a_durable_probe_verdict_is_cached() {
  local rec id_a id_b launch probes
  id_a=rc-durable-g9
  id_b=rc-durable-g10
  rec=$(make_spawn_case rc-durable claude - "$id_a" "$id_b")
  read_case_record "$rec"
  write_fake_claude "$FAKEBIN_DIR" no-flag
  FM_FAKE_CLAUDE_PROBE_LOG="$CASE_DIR/probe.log"
  : > "$FM_FAKE_CLAUDE_PROBE_LOG"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id_a")" ] \
    || fail "a claude whose help lacks the option must launch without the flag"$'\n'"actual: $launch"

  FM_FAKE_CLAUDE_MODE=supports \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$(claude_launch_without_flag "$HOME_DIR" "$id_b")" ] \
    || fail "the durable unsupported verdict must be reused for the same binary"$'\n'"actual: $launch"
  probes=$(grep -c . "$FM_FAKE_CLAUDE_PROBE_LOG")
  [ "$probes" -eq 1 ] || fail "a durable verdict must spare the second spawn a probe, probed $probes times"
  unset FM_FAKE_CLAUDE_PROBE_LOG
  pass "probe: a verdict about the binary is cached for the next spawn"
}

# --- 4. every other harness is untouched -------------------------------------

# One row per verified non-claude crewmate adapter, with the knob ABSENT, so the
# "only claude" half of the contract is proven on the reachable default path
# rather than only where a home opted in.
# Each row also asserts the harness launched at all, so a spawn that silently
# failed cannot pass as "no flag present".
#   <harness>^<task-id>^<launch-token-proving-this-harness-launched>
test_default_never_touches_another_harness() {
  local harness id token rec out status launch n=0
  while IFS='^' read -r harness id token; do
    [ -n "$harness" ] || continue
    n=$((n + 1))
    rec=$(make_spawn_case "rc-other-$harness" "$harness" - "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness spawn on the default should still succeed"$'\n'"$out"

    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--remote-control" \
      "the claude-only Remote Control flag leaked into the $harness launch"
    assert_not_contains "$launch" "__RCFLAG__" \
      "an unexpanded Remote Control placeholder leaked into the $harness launch"
    # Adjacency-free, so an inserted flag cannot break THIS assertion and mask
    # the two above; it only proves the intended adapter launched at all.
    assert_contains "$launch" "$token" \
      "$harness did not launch, so its no-flag result would be vacuous"
  done <<'ROWS'
codex^rc-other-codex-e1^--dangerously-bypass-approvals-and-sandbox
opencode^rc-other-opencode-e2^OPENCODE_CONFIG_CONTENT=
grok^rc-other-grok-e3^--always-approve
pi^rc-other-pi-e5^--tui-mode
cursor^rc-other-cursor-e6^--trust --yolo
gemini^rc-other-gemini-e7^GEMINI_CLI_TRUST_WORKSPACE=true
ROWS
  [ "$n" -eq 6 ] || fail "expected 6 non-claude adapter rows, ran $n"
  pass "default: no non-claude adapter's launch changes at all ($n adapters)"
}

# A raw launch command is the operator's own escape hatch for an unverified
# adapter, so firstmate must not rewrite it - not even to add the flag it adds
# to every claude launch by default.
test_default_never_rewrites_a_raw_launch_command() {
  local rec id out status launch
  id=rc-raw-e4
  rec=$(make_spawn_case rc-raw claude - "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "sh -c 'echo raw-launch'")
  status=$?
  expect_code 0 "$status" "a raw launch command should still spawn on the default"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--remote-control" \
    "a raw launch command must be typed exactly as given, never rewritten"
  assert_contains "$launch" "sh -c 'echo raw-launch'" \
    "the raw launch command did not reach the pane, so its no-flag result would be vacuous"
  pass "default: a raw launch command is typed unchanged"
}

# --- 5. secondmates are excluded ---------------------------------------------

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

test_default_never_reaches_a_secondmate_launch() {
  local rec id out status launch sm
  id=rc-secondmate-f1
  rec=$(make_spawn_case rc-secondmate claude - "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/sm-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(FM_SKIP_SECONDMATE_INHERIT=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "claude secondmate spawn should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions" \
    "the secondmate did not launch on claude, so its no-flag result would be vacuous"
  assert_not_contains "$launch" "--remote-control" \
    "the crewmate Remote Control default must never reach a secondmate launch"
  pass "default: a claude secondmate launch is untouched"
}

# --- 6. composition with the paths that surround the launch ------------------

# Two things around this launch path changed after the flag was designed, and
# neither is assumed here. fm-spawn now moves this home's backlog item to In
# flight itself, and an ordinary steer is no longer typed payload but a durable
# inbox record plus one constant doorbell line. A worker firstmate cannot steer,
# or cannot account for, would be worse than a worker it cannot reach from a
# phone, so both are asserted with the flag provably on the launch.
# tests/fm-backlog-atomicity.test.sh and tests/fm-send-inbox.test.sh own those
# two contracts; these cases own only that Remote Control leaves them intact.

test_a_default_on_launch_still_moves_the_backlog_item_in_flight() {
  local rec id out status launch state
  command -v tasks-axi >/dev/null 2>&1 || {
    echo "skip: tasks-axi is not installed, so the automatic backlog transition is inert"
    return 0
  }
  id=rc-backlog-g1
  rec=$(make_spawn_case rc-backlog claude - "$id")
  read_case_record "$rec"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$HOME_DIR/data/backlog.md"
  tasks-axi add "$id" "item for $id" --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a default-on spawn against a real backlog should succeed"$'\n'"$out"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--remote-control '$(expected_rc_name "$HOME_DIR" "$id")'" \
    "the flag must be on this launch, or the transition assertion below proves nothing about it"
  state=$(tasks-axi show "$id" --file "$HOME_DIR/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1)
  [ "$state" = in_flight ] \
    || fail "a Remote-Control-enabled dispatch must still move its backlog item to In flight"$'\n'"actual state: $state"
  pass "default: the launch still moves the home's backlog item to In flight"
}

test_a_default_on_worker_is_still_steerable_through_the_durable_inbox() {
  local rec id out status launch record body doorbell typed window
  id=rc-steer-g2
  rec=$(make_spawn_case rc-steer claude - "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the spawn under steer should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--remote-control '$(expected_rc_name "$HOME_DIR" "$id")'" \
    "the flag must be on this launch, or the steer assertions below prove nothing about it"

  # A real steer of the record this spawn published, through the real fm-send.
  # The spawn-world tmux stub answers only the launch path, while fm-send's
  # doorbell first has to reach a clean endpoint-liveness and composer verdict,
  # so the send half of this case runs against the shared send-world stub and
  # logs the typed text to the same file the launch assertions above read.
  : > "$LAUNCH_LOG"
  fm_test_fake_tmux_send "$FAKEBIN_DIR"
  # The doorbell is only typed at an endpoint whose recorded window is actually
  # present in the session inventory; the liveness probe's other sources are
  # grounded in real tty and process facts a stub cannot forge, and a readable
  # endpoint is all this case needs.
  window=$(sed -n 's/^window=//p' "$HOME_DIR/state/$id.meta" | head -1)
  out=$(FM_FAKE_TMUX_WINDOWS="${window#*:}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SEND_SETTLE=0 FM_SEND_LOG="$LAUNCH_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-send.sh" "$id" "keep going, and report the failing case" 2>&1)
  status=$?
  expect_code 0 "$status" "steering a Remote-Control-enabled worker should succeed"$'\n'"$out"

  record=$(find "$HOME_DIR/state/$id.inbox" -maxdepth 1 -name '*.msg' | sort | head -1)
  [ -n "$record" ] \
    || fail "the steer left no durable instruction record for a Remote-Control-enabled worker"
  body=$(cat "$record")
  assert_contains "$body" "keep going, and report the failing case" \
    "the durable record must carry the steer body"

  typed=$(cat "$LAUNCH_LOG")
  assert_not_contains "$typed" "keep going, and report the failing case" \
    "the steer payload must stay off the terminal for a Remote-Control-enabled worker too"
  # The doorbell's exact wording is owned by bin/fm-task-inbox-lib.sh; this case
  # only needs the constant line to have reached a Remote-Control-enabled pane,
  # so it matches that renderer's quoted-path form rather than restating it.
  doorbell=$(printf "Firstmate instruction waiting: list '%s'/*.msg" "$(cd "$HOME_DIR/state/$id.inbox" && pwd)")
  assert_contains "$typed" "$doorbell" \
    "the constant doorbell must still reach a Remote-Control-enabled pane"
  pass "default: a Remote-Control-enabled worker is still steered by durable record plus doorbell"
}

# --- inheritance -------------------------------------------------------------

# The knob governs the crewmates a home spawns, exactly like config/crew-harness,
# so a secondmate's OWN claude crewmates must inherit it and an explicit "off"
# must propagate. The allowlist is the one owner of that decision
# (bin/fm-config-inherit-lib.sh), and both ends of a remote transfer derive from
# it, so membership is asserted through the declared item list rather than
# restated anywhere else.
test_knob_is_declared_inheritable() {
  local items
  items=$(fm_config_inherit_items)
  assert_contains "$items" "config/crew-remote-control" \
    "config/crew-remote-control must be inherited into secondmate homes so an explicit off propagates"
  assert_contains "$items" "config/crew-harness" \
    "the crew-harness sibling must still be inherited, so this assertion is not vacuous"
  pass "config/crew-remote-control is declared inheritable alongside config/crew-harness"
}

test_default_launches_claude_with_remote_control
test_default_launches_a_scout_with_remote_control
test_default_names_the_session_before_the_positional_brief
test_default_composes_with_model_and_effort
test_session_name_is_qualified_by_the_home
test_every_launch_gets_a_distinct_session_name
test_the_name_caps_hold
test_off_leaves_the_claude_launch_unchanged
test_off_leaves_a_scout_launch_unchanged
test_off_is_read_case_and_whitespace_insensitively
test_enabling_values_keep_remote_control_on
test_unrecognized_value_warns_and_falls_back_to_the_default
test_claude_without_the_option_launches_unchanged
test_prefix_option_alone_does_not_enable_the_flag
test_a_failed_probe_launches_unchanged_and_still_spawns
test_probe_verdict_is_cached_but_follows_the_binary
test_the_probe_uses_the_shared_bounded_runner
test_a_transient_probe_failure_is_not_cached
test_a_probe_that_hits_the_bound_is_not_cached
test_a_durable_probe_verdict_is_cached
test_default_never_touches_another_harness
test_default_never_rewrites_a_raw_launch_command
test_default_never_reaches_a_secondmate_launch
test_a_default_on_launch_still_moves_the_backlog_item_in_flight
test_a_default_on_worker_is_still_steerable_through_the_durable_inbox
test_knob_is_declared_inheritable

echo "# all fm-crew-remote-control tests passed"
