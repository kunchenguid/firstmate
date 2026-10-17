#!/usr/bin/env bash
# Tests for fm-tool-update-check.sh, the watched tooling update report.
#
# The case that matters most is PATH skew: a tool that has already installed its
# newer copy, while PATH still resolves an older one. On 2026-08-20 that exact
# shape broke this fleet. Herdr self-installed 0.8.2 into ~/.local/bin, a version
# manager kept its own 0.8.0 earlier on PATH inside a directory named "latest",
# and every Herdr command then failed on a protocol mismatch. A check that only
# asks "is a newer version published" reports everything up to date and misses
# it, so test_path_skew_is_reported_from_every_copy reproduces the incident and
# asserts the report names the older copy PATH resolves AND the newer copy that
# is already installed. A single `command -v` lookup cannot know the second
# version, so that assertion fails against any build without real per-copy
# probing.
#
# The fixtures use a synthetic command name and their own temporary PATH
# directories, so no case ever probes, launches, or otherwise touches a tool
# actually installed on this host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-tool-update-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-tool-update-check)

# Exported here, at the top level, because git_fixture runs inside a command
# substitution and an export from that subshell never reaches the cases, which
# make fixture commits of their own. A host with no git identity configured
# would otherwise fail those commits and leave the fixture in a shape the case
# did not ask for.
fm_git_identity fmtest fmtest@example.invalid

# The incident's tool, under a name that cannot exist on this host.
TOOL=herdr-fixture

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# make_copy <dir> <command> <version-output>: an executable copy that answers
# --version with the given text and nothing else.
make_copy() {
  local dir=$1 command_name=$2 text=$3
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
printf '%s\n' '$text'
SH
  chmod 0755 "$dir/$command_name"
}

# make_slow_copy <dir> <command> <seconds>: a copy that answers far too late, so a
# case can spend the sweep budget the way a hung tool would.
make_slow_copy() {
  local dir=$1 command_name=$2 seconds=$3
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
sleep $seconds
printf 'herdr 0.8.2\n'
SH
  chmod 0755 "$dir/$command_name"
}

# make_hanging_copy <dir> <command> <version-output> <seconds>: a copy that prints
# what looks like a whole answer and then hangs, so its probe is cut short with its
# partial output already in hand. A copy can fail this way for real - a version
# banner flushed before a network lookup stalls - and the printed text is not an
# answer, because nothing says the copy was finished talking.
# A copy that reports its version at once and then stalls on every other command,
# so the probe that is cut short is the one asking it to announce its update.
make_mute_announce_copy() {
  local dir=$1 command_name=$2 text=$3 seconds=$4
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf '%s\n' '$text'
  exit 0
fi
sleep $seconds
SH
  chmod 0755 "$dir/$command_name"
}
make_hanging_copy() {
  local dir=$1 command_name=$2 text=$3 seconds=$4
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
printf '%s\n' '$text'
sleep $seconds
SH
  chmod 0755 "$dir/$command_name"
}

# make_killed_copy <dir> <command>: a copy that is killed before it can answer, so
# a case can exercise a probe cut short by a signal rather than by its own bound.
# The bounded runner reports that as 128 plus the signal, not as its timeout
# status, and neither one established anything about the copy.
make_killed_copy() {
  local dir=$1 command_name=$2
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<'SH'
#!/usr/bin/env bash
kill -KILL $$
SH
  chmod 0755 "$dir/$command_name"
}

# make_counting_copy <dir> <command> <version-output> <log>: the same copy, which
# also appends one line to <log> every time it runs, so a case can assert how
# many times the check actually probed it.
make_counting_copy() {
  local dir=$1 command_name=$2 text=$3 log=$4
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
printf 'probed\n' >> '$log'
printf '%s\n' '$text'
SH
  chmod 0755 "$dir/$command_name"
}

write_config() {
  local home=$1
  shift
  printf '%s\n' "$*" > "$home/config/watched-tools.json"
}

# The fixture directories first, then the ambient PATH, which the check needs
# because it shells out to ordinary tools such as jq, git, date, grep, stat, and
# timeout. What keeps a tool installed on this host out of a fixture is the
# synthetic command name, not this PATH, so every case watches a command name
# that cannot exist here.
fixture_path() {
  printf '%s:%s\n' "$1" "$PATH"
}

# The watcher check timeout is pinned to its documented default here, because the
# sweep budget is cut to fit it and an operator's ambient value would otherwise
# add a report line to cases that mean to be silent. The one case that exercises
# the cut sets its own value.
run_check() {
  local home=$1 path=$2 out=$3
  shift 3
  local status=0
  env FM_CHECK_TIMEOUT=30 "$@" FM_HOME="$home" PATH="$path" FM_TOOL_UPDATE_INTERVAL=0 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# A check that gets no answer at all is held back until the same kind of check for
# the same tool has gone unanswered three sweeps in a row, so a case about what
# such a sweep reports has to run that streak out. What the last sweep printed is
# what lands in <out>; the earlier sweeps of the streak are expected to be silent.
UNANSWERED_STREAK=3
run_check_until_unanswered() {
  local home=$1 path=$2 out=$3
  shift 3
  local i=0
  while [ "$i" -lt "$UNANSWERED_STREAK" ]; do
    i=$((i + 1))
    run_check "$home" "$path" "$out" "$@"
    if [ "$i" -lt "$UNANSWERED_STREAK" ] && [ -s "$out" ]; then
      # An earlier sweep of the streak spoke, which means what it reported was
      # never held back as an unanswered condition at all. Failing here rather
      # than handing that early output to the case is what makes the cases that
      # assert on <out> proof of the delay: a build that reports an unanswered
      # check on its first sweep prints the same text, and would otherwise pass.
      fail "sweep $i of $UNANSWERED_STREAK reported '$(cat "$out")' instead of holding it back until the streak ran out"
    fi
  done
}

# --- the regression this script exists for ----------------------------------

test_path_skew_is_reported_from_every_copy() {
  local home stale fresh out report
  home=$(make_home skew)
  # The stale copy sits in a directory named "latest" on purpose: the incident's
  # version manager did exactly that, so a directory name is no evidence at all.
  stale="$TMP_ROOT/skew/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/skew/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\",\"version_args\":[\"--version\"]}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$stale:$fresh")" "$out"
  report=$(cat "$out")

  assert_contains "$report" "herdr update not in effect" "PATH skew was not reported as an update that is not in effect"
  # Both sides of the comparison must be named, and the newer one can only be
  # known by asking a copy other than the one PATH resolves.
  assert_contains "$report" "PATH resolves 0.8.0 at $stale/$TOOL" "the report does not name the older version PATH actually resolves"
  assert_contains "$report" "0.8.2 is installed at $fresh/$TOOL" "the report does not name the newer installed copy, so no other PATH copy was asked for its version"
  assert_not_contains "$report" "update available" "PATH skew must not be reported as a published update"
  assert_contains "$report" "$(printf 'tool updates:')" "the report is missing its one-line prefix"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must be exactly one line for the wake record"
  pass "PATH skew is reported by asking every copy on PATH for its own version"
}

test_newest_copy_first_on_path_is_silent() {
  local home stale fresh out
  # Control for the case above: the same two copies, the newer one resolved
  # first, must produce no report at all.
  home=$(make_home no-skew)
  stale="$TMP_ROOT/no-skew/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/no-skew/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$fresh:$stale")" "$out"
  [ ! -s "$out" ] || fail "check reported skew when PATH already resolves the newest copy: $(cat "$out")"
  pass "no report when PATH already resolves the newest installed copy"
}

test_identical_versions_are_silent() {
  local home first second out
  home=$(make_home same-version)
  first="$TMP_ROOT/same-version/a/bin"
  second="$TMP_ROOT/same-version/b/bin"
  make_copy "$first" "$TOOL" 'herdr 0.8.2'
  make_copy "$second" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$first:$second")" "$out"
  [ ! -s "$out" ] || fail "two copies of the same version reported skew: $(cat "$out")"
  pass "two copies of the same version are not skew"
}

test_one_copy_reached_twice_is_probed_once() {
  local home dir link out log probes
  # A single install reachable through two PATH entries must not read as two
  # installs, or a symlinked bin directory would report skew against itself.
  # Silence alone does not prove that, because two answers of the same version
  # are silent too, so count the probes: the one install must be asked once.
  home=$(make_home one-copy)
  dir="$TMP_ROOT/one-copy/real/bin"
  link="$TMP_ROOT/one-copy/linked-bin"
  log="$TMP_ROOT/one-copy/probes.log"
  make_counting_copy "$dir" "$TOOL" 'herdr 0.8.2' "$log"
  ln -s "$dir" "$link"
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  : > "$log"
  run_check "$home" "$(fixture_path "$dir:$link")" "$out"
  [ ! -s "$out" ] || fail "one copy reached through two PATH entries reported a finding: $(cat "$out")"
  probes=$(wc -l < "$log" | tr -d ' ')
  [ "$probes" = 1 ] || fail "one install reached through two PATH entries was probed $probes times, so the two entries were not recognized as one install"
  pass "one copy reached through two PATH entries is probed once as one install"
}

test_unreadable_version_is_a_failure_not_a_pass() {
  local home dir out report
  # A copy that will not say what it is cannot be called current.
  home=$(make_home mute)
  dir="$TMP_ROOT/mute/bin"
  make_copy "$dir" "$TOOL" 'no version here'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "herdr check failed" "a copy that reports no version was treated as current"
  assert_contains "$report" "$dir/$TOOL did not report a version" "the failing copy was not named"
  pass "a copy that reports no version is a check failure, not a pass"
}

test_missing_command_is_reported() {
  local home out
  home=$(make_home absent)
  write_config "$home" '{"tools":[{"name":"herdr","command":"herdr-absent-fixture"}]}'
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "herdr check failed: herdr-absent-fixture is not on PATH" "a watched command missing from PATH was not reported"
  pass "a watched command missing from PATH is reported"
}

# --- published updates ------------------------------------------------------

test_announced_update_is_reported_from_the_tool_itself() {
  local home dir out report
  # no-mistakes already announces its own update on stderr; read that rather
  # than reimplementing its version lookup.
  home=$(make_home announce)
  dir="$TMP_ROOT/announce/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
printf '1.46.0\n'
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.47.0\n' >&2
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes update available: A new version of no-mistakes is available: v1.46.0 -> v1.47.0" "the tool's own update announcement was not reported"
  assert_not_contains "$report" "not in effect" "a published update must not be reported as PATH skew"
  pass "a tool's own update announcement is read from its output"
}

test_announced_update_already_installed_is_not_double_reported() {
  local home first second out report
  # One completed install: the newer copy sits on PATH behind the older
  # self-installing copy, so PATH skew is already reported. The older copy
  # keeps announcing the very release it has already been superseded by, and
  # that announcement must not also be read as a still-available update.
  home=$(make_home announce-installed)
  first="$TMP_ROOT/announce-installed/old/bin"
  second="$TMP_ROOT/announce-installed/new/bin"
  mkdir -p "$first" "$second"
  cat > "$first/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
printf '1.46.0\n'
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.47.0\n' >&2
SH
  chmod 0755 "$first/no-mistakes-fixture"
  make_copy "$second" "no-mistakes-fixture" '1.47.0'
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$first:$second")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes update not in effect" "the already-installed newer copy was not reported as PATH skew"
  assert_not_contains "$report" "update available" "an announcement naming an already-installed version was also reported as a still-available update"
  pass "an announcement naming an already-installed version is not also reported as an available update"
}

test_announced_update_newer_than_installed_is_still_reported() {
  local home first second out report
  # Control: the announced version is genuinely newer than every installed
  # copy, so it must still be reported as available alongside the skew.
  home=$(make_home announce-not-installed)
  first="$TMP_ROOT/announce-not-installed/old/bin"
  second="$TMP_ROOT/announce-not-installed/new/bin"
  mkdir -p "$first" "$second"
  cat > "$first/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
printf '1.46.0\n'
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.47.0\n' >&2
SH
  chmod 0755 "$first/no-mistakes-fixture"
  make_copy "$second" "no-mistakes-fixture" '1.46.5'
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$first:$second")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes update available: A new version of no-mistakes is available: v1.46.0 -> v1.47.0" "an announcement naming a version newer than every installed copy was not reported"
  assert_contains "$report" "no-mistakes update not in effect" "the installed newer-than-resolved copy was not reported as PATH skew"
  pass "an announcement naming a version newer than every installed copy is still reported as available"
}

test_announcement_is_read_from_a_second_command() {
  local home dir out report quiet_home
  # The real no-mistakes prints its version for --version but announces a new
  # release only on its other commands, so the announcement has to be asked of a
  # command of its own while the version probe keeps reporting the version.
  home=$(make_home announce-args)
  dir="$TMP_ROOT/announce-args/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version v1.46.0\n'
  exit 0
fi
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.53.0\n' >&2
printf 'Usage: no-mistakes <command>\n'
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  out="$home/out.txt"

  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  run_check "$home" "$(fixture_path "$dir")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes update available: A new version of no-mistakes is available: v1.46.0 -> v1.53.0" "the announcement was not read from the command that carries it"
  assert_not_contains "$report" "check failed" "the version probe stopped reporting this copy's version"

  # Control: the same tool watched without announce_args sees only the version
  # probe, which never carries the announcement, so the update is missed.
  quiet_home=$(make_home announce-args-control)
  write_config "$quiet_home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  run_check "$quiet_home" "$(fixture_path "$dir")" "$quiet_home/out.txt"
  [ ! -s "$quiet_home/out.txt" ] || fail "the control home reported without a second command, so this test proves nothing: $(cat "$quiet_home/out.txt")"
  pass "an announcement carried by another command is read from that command"
}

test_unusable_announce_pattern_is_reported_not_read_as_silence() {
  local home dir out status
  # A pattern the search cannot use answers exactly like a tool with nothing to
  # announce, which is the silently dead update source this check exists to
  # prevent. It is reported as that tool's own check failure.
  home=$(make_home bad-pattern)
  dir="$TMP_ROOT/bad-pattern/bin"
  make_copy "$dir" no-mistakes-fixture 'no-mistakes version v1.46.0'
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: ([^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  assert_contains "$(cat "$out")" "no-mistakes check failed: announce_pattern is not a usable extended regular expression" "a pattern that cannot be used was read as nothing to announce"

  # Arming is a deliberate operator action, so the same registry refuses it
  # rather than arming a check with a source that can never fire.
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with an unusable announce_pattern exit"
  assert_absent "$home/state/tool-updates.check.sh" "arm registered a check whose announcement source cannot fire"
  pass "an announce_pattern that cannot be used is reported instead of read as silence"
}

test_one_broken_pattern_does_not_blind_the_rest_of_the_sweep() {
  local home stale fresh dir out report
  # A one character typo in one tool's pattern must not turn off the detector for
  # every other tool. The PATH skew below is the whole reason this check exists,
  # so it has to be reported in the same sweep as the pattern problem.
  home=$(make_home pattern-blind)
  stale="$TMP_ROOT/pattern-blind/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/pattern-blind/local/bin"
  dir="$TMP_ROOT/pattern-blind/announce/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  make_copy "$dir" no-mistakes-fixture 'no-mistakes version v1.46.0'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"},{\"name\":\"no-mistakes\",\"command\":\"no-mistakes-fixture\",\"announce_pattern\":\"A new version of no-mistakes is available: ([^ ]+ -> [^ ]+\"}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$stale:$fresh:$dir")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "herdr update not in effect: PATH resolves 0.8.0 at $stale/$TOOL" "a broken pattern on another tool suppressed the PATH skew report"
  assert_contains "$report" "no-mistakes check failed: announce_pattern is not a usable extended regular expression" "the tool whose pattern cannot be used was not named"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must stay exactly one line"
  pass "a broken pattern is reported for its own tool and the rest of the sweep still reports"
}

test_an_unchecked_announcement_source_is_not_read_as_current() {
  local home dir out report
  # When the budget is gone the separate announcement command cannot run, and the
  # version probe's output never carries the announcement. Searching that output
  # anyway would present a source that was never asked as a clean result, which is
  # the same silently dead source announce_args was added to close.
  home=$(make_home announce-budget)
  dir="$TMP_ROOT/announce-budget/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version v1.46.0\n'
  sleep 30
  exit 0
fi
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.53.0\n' >&2
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  # The deadline is whole-second granular (real_epoch is `date +%s`), so a
  # budget of 1 leaves headroom anywhere in (0, 1] seconds: when the sweep
  # starts near the end of a second the very first budget check already reads
  # as exhausted and the sweep reports "before every copy answered" instead of
  # reaching the announcement step this case is about. A budget of 2 guarantees
  # more than a full second of headroom for the millisecond-scale work before
  # the copy loop, while the version probe below (bounded, then sleeping 30)
  # still exhausts the budget before the announcement check.
  run_check_until_unanswered "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_BUDGET_SECS=2
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes check failed: the time budget ran out before the update announcement was checked" "an announcement source that was never asked was not reported"
  pass "an announcement source the budget could not reach is reported, not read as current"
}

test_an_announcement_probe_that_does_not_answer_is_reported() {
  local home dir out report
  # no-mistakes learns about a new release from the network, so the command that
  # carries the announcement is exactly the one that stalls on a flaky link. A
  # source that was asked and never answered must not read as a clean sweep.
  home=$(make_home announce-mute)
  dir="$TMP_ROOT/announce-mute/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version v1.46.0\n'
  exit 0
fi
sleep 30
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check_until_unanswered "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes check failed: $dir/no-mistakes-fixture did not answer when asked for its update announcement" "an announcement probe that never answered was read as a clean sweep"
  pass "an announcement probe that does not answer is reported, not read as current"
}

test_an_unanswered_announcement_withholds_the_skew_it_never_established() {
  local home stale fresh out path i entries
  # A check goes unanswered from whichever probe stalls first, and the announcement
  # probe is one of them: the skew between the copies rests on a tool this check
  # never heard out, so it is no conclusion either. Reporting it would wake the
  # operator on every sweep with a flaky link, and each fresh text would be
  # remembered as one more entry, which is why the newest copy here answers with a
  # different version every sweep: any skew reported would be news rather than a
  # repeat, and would pile up in the record.
  home=$(make_home announce-mute-skew)
  stale="$TMP_ROOT/announce-mute-skew/mise/installs/nm/latest/bin"
  fresh="$TMP_ROOT/announce-mute-skew/local/bin"
  make_mute_announce_copy "$stale" nm-fixture 'nm version v1.46.0' 30
  write_config "$home" '{"tools":[{"name":"nm","command":"nm-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of nm is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  path=$(fixture_path "$stale:$fresh")

  i=0
  while [ "$i" -lt "$UNANSWERED_STREAK" ]; do
    i=$((i + 1))
    make_mute_announce_copy "$fresh" nm-fixture "nm version v1.5$i.0" 30
    run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
    assert_not_contains "$(cat "$out")" "update not in effect" "a check whose announcement source never answered claimed to know the skew"
  done

  assert_contains "$(cat "$out")" "nm check failed: $stale/nm-fixture did not answer when asked for its update announcement" "the stalled announcement was never reported, so this case proves nothing"
  entries=$(tr '\t' '\n' < "$home/state/.tool-updates" | grep -c 'update not in effect' || true)
  [ "$entries" = 0 ] || fail "a check with no answer remembered $entries updates it never established"
  pass "an unanswered announcement withholds the skew and remembers no update"
}

test_quiet_tool_with_announce_pattern_is_silent() {
  local home dir out
  home=$(make_home announce-quiet)
  dir="$TMP_ROOT/announce-quiet/bin"
  make_copy "$dir" no-mistakes-fixture '1.46.0'
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  [ ! -s "$out" ] || fail "a tool announcing nothing produced a report: $(cat "$out")"
  pass "a tool that announces nothing stays silent"
}

# --- git sources ------------------------------------------------------------

# git_fixture <name>: a work repo whose origin branch is two commits ahead,
# with those commits already present locally so the count is exact.
git_fixture() {
  local name=$1 bare work
  bare="$TMP_ROOT/$name.git"
  work="$TMP_ROOT/$name"
  git init -q --bare --initial-branch=main "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  printf 'one\n' > "$work/f1"
  git -C "$work" add f1
  git -C "$work" commit -qm one
  printf 'two\n' > "$work/f2"
  git -C "$work" add f2
  git -C "$work" commit -qm two
  printf 'three\n' > "$work/f3"
  git -C "$work" add f3
  git -C "$work" commit -qm three
  git -C "$work" push -q origin main
  git -C "$work" remote set-head origin main >/dev/null 2>&1
  printf '%s\n' "$work"
}

test_commits_behind_origin_are_reported() {
  local home work out head_before
  home=$(make_home git-behind)
  work=$(git_fixture git-behind-repo)
  git -C "$work" reset -q --hard HEAD~2
  head_before=$(git -C "$work" rev-parse HEAD)
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 2 commits behind origin/main" "commits behind the origin branch were not reported"
  # The probe is read-only: the watched repository must be untouched.
  [ "$(git -C "$work" rev-parse HEAD)" = "$head_before" ] || fail "the check moved the watched repository's HEAD"
  git -C "$work" diff --quiet || fail "the check left changes in the watched repository"
  pass "commits behind the origin branch are reported without touching the repository"
}

test_default_branch_is_detected_when_branch_is_omitted() {
  local home work out
  home=$(make_home git-default)
  work=$(git_fixture git-default-repo)
  git -C "$work" reset -q --hard origin/main~1
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 1 commit behind origin/main" "the default branch was not detected from the remote"
  pass "an omitted branch is detected from the remote's default branch"
}

test_default_branch_is_asked_of_the_remote_when_the_clone_has_no_record() {
  local home work out
  # A --single-branch clone, or one that never ran remote set-head, has no local
  # refs/remotes/origin/HEAD. The remote still knows its default branch, so this
  # must report the update rather than an unactionable check failure.
  home=$(make_home git-symref)
  work=$(git_fixture git-symref-repo)
  git -C "$work" remote set-head origin --delete >/dev/null 2>&1
  git -C "$work" reset -q --hard HEAD~2
  # Ask git what it knows rather than looking for a loose ref file, which never
  # exists under a non-loose ref backend and would make this vacuous there.
  ! git -C "$work" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
    || fail "the fixture still records the remote's default branch locally"
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 2 commits behind origin/main" "the default branch was not asked of the remote"
  pass "the default branch is asked of the remote when the clone has no local record"
}

test_current_and_ahead_repositories_are_silent() {
  local home work out
  home=$(make_home git-current)
  work=$(git_fixture git-current-repo)
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  [ ! -s "$out" ] || fail "an up to date repository produced a report: $(cat "$out")"

  printf 'local only\n' > "$work/f4"
  git -C "$work" add f4
  git -C "$work" commit -qm four
  rm -f "$home/state/.tool-updates"
  run_check "$home" "$PATH" "$out"
  [ ! -s "$out" ] || fail "a repository ahead of its origin branch produced a report: $(cat "$out")"
  pass "a repository that is current or ahead of its origin branch is silent"
}

test_unusable_git_source_is_reported() {
  local home out
  home=$(make_home git-broken)
  mkdir -p "$TMP_ROOT/git-broken/not-a-repo"
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$TMP_ROOT/git-broken/not-a-repo\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate check failed" "an unusable git source was not reported"
  pass "an unusable git source is reported as a check failure"
}

test_unreadable_remote_is_not_reported_as_a_missing_branch() {
  local home work out report
  # A remote that cannot be reached at all and a branch that was deleted are
  # different problems with different repairs. Reporting the first as the second
  # wakes firstmate with a diagnosis that is simply wrong, so the report must
  # name only what the probe established.
  home=$(make_home git-unreadable)
  work=$(git_fixture git-unreadable-repo)
  rm -rf "$TMP_ROOT/git-unreadable-repo.git"
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check_until_unanswered "$home" "$PATH" "$out"
  report=$(cat "$out")
  assert_contains "$report" "firstmate check failed" "a remote that could not be read was not reported"
  assert_contains "$report" "origin could not be reached or read" "the report does not name the condition the probe actually found"
  assert_not_contains "$report" "has no branch" "a remote that could not be read was reported as a deleted branch"
  pass "a remote that cannot be read is reported as unreadable, not as a missing branch"
}

test_missing_branch_on_a_readable_remote_is_still_reported() {
  local home work out
  # The other side of the case above: the remote answers, and it really does not
  # have the watched branch, so that must still be reported as a missing branch.
  home=$(make_home git-no-branch)
  work=$(git_fixture git-no-branch-repo)
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"release\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate check failed: origin has no branch release" "a branch the remote does not have was not reported as missing"
  pass "a branch a readable remote does not have is still reported as missing"
}

test_git_probes_stop_when_the_sweep_budget_is_gone() {
  local home work slow out report
  # The git probes are the several-in-a-row case, two of them over the network,
  # so they are the ones that can push a sweep past the watcher's own timeout and
  # leave it killed with nothing printed at all. Here the tool's command probe
  # spends the whole budget, so its git probes must not start: the sweep says
  # which tool it did not finish instead of quietly running on.
  home=$(make_home git-budget)
  work=$(git_fixture git-budget-repo)
  git -C "$work" reset -q --hard HEAD~2
  slow="$TMP_ROOT/git-budget/bin"
  make_slow_copy "$slow" "$TOOL" 30
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"command\":\"$TOOL\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check_until_unanswered "$home" "$(fixture_path "$slow")" "$out" FM_TOOL_UPDATE_BUDGET_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "check incomplete: the time budget ran out before firstmate" "a sweep with no budget left did not say which tool it did not finish"
  assert_not_contains "$report" "commits behind" "the git probes ran after the sweep budget was already gone"
  pass "git probes stop and name their tool once the sweep budget is gone"
}

test_a_git_probe_that_does_not_answer_is_not_an_update() {
  local home work dir out report head_before
  # The local git probes are bounded too, so a bound that is hit must not be read
  # as the answer "this clone does not have that commit". This clone is ahead of
  # its remote branch, which is silent when the probes answer, so any claim of an
  # available update here was never established.
  home=$(make_home git-mute)
  work=$(git_fixture git-mute-repo)
  printf 'local only\n' > "$work/f4"
  git -C "$work" add f4
  git -C "$work" commit -qm four
  head_before=$(git -C "$work" rev-parse HEAD)

  # A git that answers everything except the object query, which never answers.
  dir="$TMP_ROOT/git-mute/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = cat-file ]; then
    sleep 30
    exit 0
  fi
done
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  # The bound is wide enough that the earlier probes answer comfortably, so the
  # only probe that can hit it is the object query the fixture stalls. Asserting
  # that specific report keeps an unrelated timeout from passing this case for the
  # wrong reason.
  run_check_until_unanswered "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_PROBE_SECS=3
  report=$(cat "$out")
  assert_not_contains "$report" "update available" "a probe that never answered was reported as an available update"
  assert_contains "$report" "firstmate check failed: $work did not answer whether it already has" "the stalled object query was not the reported failure"
  [ "$(git -C "$work" rev-parse HEAD)" = "$head_before" ] || fail "the check moved the watched repository's HEAD"
  pass "a git probe that does not answer is reported as a failure, never as an update"
}

test_a_stalled_repository_probe_is_not_reported_as_not_a_repository() {
  local home work dir out report
  # The very first git probe is bounded too. A clone on a stalled mount that
  # never answers must be reported as not answering, not as not being a git
  # repository, which is a diagnosis the probe never established.
  home=$(make_home git-stall)
  work=$(git_fixture git-stall-repo)
  git -C "$work" reset -q --hard HEAD~2

  dir="$TMP_ROOT/git-stall/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = rev-parse ]; then
    sleep 30
    exit 0
  fi
done
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check_until_unanswered "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "firstmate check failed: $work did not answer whether it is a git repository" "a repository probe that never answered was not reported as such"
  assert_not_contains "$report" "is not a git repository" "a repository probe that never answered was reported as not a repository"
  pass "a stalled repository probe is reported as no answer, not as not a repository"
}

# --- registry and reporting contract ----------------------------------------

test_absent_registry_is_silent() {
  local home out
  home=$(make_home no-config)
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  [ ! -s "$out" ] || fail "check spoke without a watched tool registry: $(cat "$out")"
  assert_absent "$home/state/.tool-updates" "check wrote a record without a registry"
  pass "no watched tool registry means no output at all"
}

test_malformed_registry_is_reported_not_ignored() {
  local home out
  home=$(make_home bad-config)
  printf 'not json at all\n' > "$home/config/watched-tools.json"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "watched tool registry: the watched tool registry is not valid JSON" "a malformed registry was silently ignored"

  printf '%s\n' '{"tools":[{"name":"herdr"}]}' > "$home/config/watched-tools.json"
  rm -f "$home/state/.tool-updates"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "tool herdr needs command, git, or both" "a tool entry with no update source was accepted"

  printf '%s\n' '{"tools":[{"name":"herdr","command":"herdr; rm -rf /"}]}' > "$home/config/watched-tools.json"
  rm -f "$home/state/.tool-updates"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "command must be a bare executable name" "a command name with shell characters was accepted"

  printf '%s\n' '{"tools":[{"name":"herdr","command":"herdr","announce_args":["--help"]}]}' > "$home/config/watched-tools.json"
  rm -f "$home/state/.tool-updates"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "tool herdr announce_args needs announce_pattern" "a command to search with no pattern to search for was accepted"
  pass "a malformed registry is reported instead of quietly skipped"
}

test_findings_are_reported_once_until_they_change() {
  local home stale fresh out path
  home=$(make_home no-nag)
  stale="$TMP_ROOT/no-nag/old/bin"
  fresh="$TMP_ROOT/no-nag/new/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$stale:$fresh")

  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "not in effect" "the first sweep did not report the pending update"
  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "the same pending update was reported twice: $(cat "$out")"

  # A changed finding is news again.
  make_copy "$fresh" "$TOOL" 'herdr 0.9.0'
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "0.9.0 is installed" "a changed finding was suppressed as a repeat"

  # Once the condition clears, the report clears with it, and a later return of
  # the same condition is reported again.
  make_copy "$stale" "$TOOL" 'herdr 0.9.0'
  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "a cleared finding still produced a report: $(cat "$out")"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "PATH resolves 0.8.0" "a returning finding was not reported again"
  pass "the same pending update is reported once, and a change is reported again"
}

test_a_flaky_remote_does_not_repeat_a_reported_update() {
  local home work dir out path
  # A remote that answers on one sweep and not the next must not make the same
  # pending update news again: an unanswered probe says nothing about the update
  # already reported, so it must not erase the memory of that report.
  home=$(make_home flaky)
  work=$(git_fixture flaky-repo)
  git -C "$work" reset -q --hard HEAD~2

  # A git whose network read stalls whenever the flag file exists.
  dir="$TMP_ROOT/flaky/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
if [ -e '$TMP_ROOT/flaky/offline' ]; then
  for arg in "\$@"; do
    if [ "\$arg" = ls-remote ]; then
      sleep 30
      exit 0
    fi
  done
fi
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"
  path=$(fixture_path "$dir")

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  assert_contains "$(cat "$out")" "firstmate update available" "the first sweep did not report the pending update"

  # A link that answers every other poll never goes unanswered long enough to be
  # worth a word, and the update it already reported is not news again either, so
  # the whole flap is silent.
  touch "$TMP_ROOT/flaky/offline"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  [ ! -s "$out" ] || fail "one unanswered read woke the operator on its own: $(cat "$out")"

  rm -f "$TMP_ROOT/flaky/offline"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  [ ! -s "$out" ] || fail "an update already reported was reported again after one unanswered read: $(cat "$out")"

  touch "$TMP_ROOT/flaky/offline"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  [ ! -s "$out" ] || fail "the second flap of the same link woke the operator: $(cat "$out")"

  rm -f "$TMP_ROOT/flaky/offline"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  [ ! -s "$out" ] || fail "the flapping remote kept reporting the same update: $(cat "$out")"

  # A genuinely new finding for the same tool is still news.
  git -C "$work" reset -q --hard origin/main~1
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  assert_contains "$(cat "$out")" "1 commit behind" "a changed update was suppressed as a repeat"
  pass "a flaky remote reports neither the same update nor the flapping itself"
}

test_a_remote_that_stays_unreachable_is_reported_once() {
  local home work dir out path i
  # Holding an unanswered read back must not bury a link that is genuinely down:
  # once the same check has gone unanswered three sweeps in a row it says so, and
  # says it once, however long the streak runs on.
  home=$(make_home persistent)
  work=$(git_fixture persistent-repo)
  git -C "$work" reset -q --hard HEAD~2
  dir="$TMP_ROOT/persistent/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
if [ -e '$TMP_ROOT/persistent/offline' ]; then
  for arg in "\$@"; do
    if [ "\$arg" = ls-remote ]; then
      printf 'fatal: could not read from remote repository\n' >&2
      exit 128
    fi
  done
fi
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"
  path=$(fixture_path "$dir")

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "firstmate update available" "the first sweep did not report the pending update"

  touch "$TMP_ROOT/persistent/offline"
  for i in 1 2; do
    run_check "$home" "$path" "$out"
    [ ! -s "$out" ] || fail "unanswered sweep $i of the streak spoke before the streak was out: $(cat "$out")"
  done
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "firstmate check failed: origin could not be reached or read from $work" "a link that stayed down for three sweeps was never reported"

  for i in 4 5; do
    run_check "$home" "$path" "$out"
    [ ! -s "$out" ] || fail "sweep $i of the same streak reported the down link again: $(cat "$out")"
  done
  pass "a remote that stays unreachable is reported once, after three unanswered sweeps"
}

test_an_unreachable_remote_keeps_the_update_when_the_branch_comes_from_the_remote() {
  local home work dir out path report
  # A clone with no local record of the remote's default branch asks the remote
  # for it, which is a network read like any other: a remote that refuses it
  # establishes nothing about the update already reported, and must not be
  # reported as a default branch this check never got to ask about either.
  home=$(make_home symref-offline)
  work=$(git_fixture symref-offline-repo)
  git -C "$work" remote set-head origin --delete >/dev/null 2>&1
  git -C "$work" reset -q --hard HEAD~2
  ! git -C "$work" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
    || fail "the fixture still records the remote's default branch locally"

  # A git whose network reads are refused outright, the way an unreachable remote
  # refuses them, whenever the flag file exists.
  dir="$TMP_ROOT/symref-offline/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
if [ -e '$TMP_ROOT/symref-offline/offline' ]; then
  for arg in "\$@"; do
    if [ "\$arg" = ls-remote ]; then
      printf 'fatal: could not read from remote repository\n' >&2
      exit 128
    fi
  done
fi
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"
  path=$(fixture_path "$dir")

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 2 commits behind origin/main" "the first sweep did not report the pending update"

  touch "$TMP_ROOT/symref-offline/offline"
  run_check_until_unanswered "$home" "$path" "$out"
  report=$(cat "$out")
  assert_contains "$report" "firstmate check failed: origin could not be reached or read from $work" "a remote that refused the read was not reported as unreachable"
  assert_not_contains "$report" "cannot resolve the default branch" "a remote that was never read was reported as having no default branch"

  rm -f "$TMP_ROOT/symref-offline/offline"
  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "an unreachable remote erased the update already reported, so it was reported again: $(cat "$out")"
  pass "an unreachable remote keeps the update when the branch is asked of the remote"
}

test_a_failure_the_probe_answered_does_not_swallow_a_returning_finding() {
  local home stale fresh out path
  # A command that is no longer on PATH is an answer, not a missing one: the
  # sweep read PATH and found nothing there. So it settles that tool's command
  # check the way a clean sweep does, and the skew that returns afterwards is a
  # returning condition, which must be reported again rather than suppressed as a
  # repeat of the report from before the tool went away.
  home=$(make_home answered-failure)
  stale="$TMP_ROOT/answered-failure/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/answered-failure/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$stale:$fresh")

  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr update not in effect" "the first sweep did not report the PATH skew"

  rm -f "$stale/$TOOL" "$fresh/$TOOL"
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr check failed: $TOOL is not on PATH" "the uninstalled tool was not reported as absent from PATH"

  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr update not in effect" "the returning skew was swallowed as a repeat of the report from before the tool was uninstalled"
  pass "a check failure the probe answered settles its kind, so a returning finding is news again"
}

test_a_copy_that_never_answered_keeps_what_it_reported() {
  local home stale fresh out path
  # The other half of the same distinction: a copy that runs out its bound
  # answered nothing at all, so it must not settle the command check and clear
  # the skew already reported. Each is reported as the thing it was, and only the
  # memory tells apart what each one did to the skew.
  home=$(make_home unanswered-copy)
  stale="$TMP_ROOT/unanswered-copy/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/unanswered-copy/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$stale:$fresh")

  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "herdr update not in effect" "the first sweep did not report the PATH skew"

  make_slow_copy "$stale" "$TOOL" 30
  run_check_until_unanswered "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "herdr check failed: $stale/$TOOL did not answer in time" "a copy that never answered was not reported"

  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  [ ! -s "$out" ] || fail "a copy that never answered erased the skew already reported, so it was reported again: $(cat "$out")"
  pass "a copy that never answered keeps what its tool's command check reported"
}

test_a_later_copy_cut_short_keeps_what_the_command_check_reported() {
  local home first middle last out path
  # The copy whose probe is cut short need not be the first one that reports no
  # version. Here an earlier copy answers with no version at all, which is an
  # answer, while a later copy times out, which is not: the comparison between the
  # copies is then incomplete whichever copy went quiet, so the skew already
  # reported must survive it.
  home=$(make_home later-cut-short)
  first="$TMP_ROOT/later-cut-short/mise/installs/herdr/latest/bin"
  middle="$TMP_ROOT/later-cut-short/mute/bin"
  last="$TMP_ROOT/later-cut-short/local/bin"
  make_copy "$first" "$TOOL" 'herdr 0.8.0'
  make_copy "$middle" "$TOOL" 'no version here'
  make_copy "$last" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$middle:$last")

  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "herdr update not in effect" "the first sweep did not report the PATH skew"

  # The newest copy now times out, so this sweep finds no skew at all: the copy
  # that would have shown it never answered.
  make_slow_copy "$last" "$TOOL" 30
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_not_contains "$(cat "$out")" "update not in effect" "a sweep whose newest copy never answered claimed to know the skew"

  make_copy "$last" "$TOOL" 'herdr 0.8.2'
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  [ ! -s "$out" ] || fail "a later copy cut short erased the skew already reported, so it was reported again: $(cat "$out")"
  pass "a copy cut short after an earlier unreadable one keeps what its command check reported"
}

test_repeated_unanswered_sweeps_keep_one_failure_per_check() {
  local home work push dir out path i entries
  # state/.tool-updates is this check's own record of what it already reported, and
  # a check that keeps getting no answer keeps its memory rather than dropping it.
  # Some unanswered texts name the remote commit they could not ask about, so a
  # remote that keeps moving would leave one distinct entry per sweep behind
  # forever. Only the newest failure of a kind is kept, so the record stays bounded
  # while the update it already reported is still remembered.
  home=$(make_home sha-bound)
  work=$(git_fixture sha-bound-repo)
  git -C "$work" reset -q --hard HEAD~2
  push="$TMP_ROOT/sha-bound-push"
  git clone -q "$TMP_ROOT/sha-bound-repo.git" "$push"

  # A git whose local commit lookups stall whenever the flag file exists, so the
  # sweep learns where the remote branch points and then runs out of answers.
  dir="$TMP_ROOT/sha-bound/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
if [ -e '$TMP_ROOT/sha-bound/offline' ]; then
  for arg in "\$@"; do
    if [ "\$arg" = cat-file ]; then
      sleep 30
      exit 0
    fi
  done
fi
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"
  path=$(fixture_path "$dir")

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "firstmate update available: local main is 2 commits behind origin/main" "the first sweep did not report the pending update"

  touch "$TMP_ROOT/sha-bound/offline"
  for i in 1 2 3 4; do
    # Each round moves the remote branch on, so the commit the stalled probe was
    # asked about differs every time and no two failure texts are alike.
    printf 'more\n' > "$push/f-$i"
    git -C "$push" add -A
    git -C "$push" commit -qm "more $i"
    git -C "$push" push -q origin main
    run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  done
  # The streak spoke once, on its third sweep, and the fourth round's changed
  # commit did not make it speak again.
  [ ! -s "$out" ] || fail "a moving remote reported the same stalled lookup again: $(cat "$out")"

  entries=$(grep -o 'did not answer whether it already has' "$home/state/.tool-updates" | wc -l | tr -d ' ')
  [ "$entries" = 1 ] \
    || fail "three unanswered sweeps left $entries remembered failures behind instead of one"
  entries=$(grep -o 'update available: local main is 2 commits behind' "$home/state/.tool-updates" | wc -l | tr -d ' ')
  [ "$entries" = 1 ] \
    || fail "the unanswered sweeps lost the update already reported, found $entries entries for it"
  pass "repeated unanswered sweeps keep one failure per check and still remember the update"
}

test_two_dead_ends_in_one_sweep_are_reported_once_each() {
  local home mute hung out path report entries
  # One kind of check can reach more than one dead end in a single sweep: a copy
  # that answers with no version in it and a copy that never answers at all are two
  # findings of the same tool's command check, and the hang leaves that check
  # without an answer, so both wait out the same streak and are said together.
  # Both then have to be remembered as said: the cap that keeps one unanswered
  # entry per kind is about what earlier sweeps left behind, and were it to drop
  # one of these instead, the dropped one would be reported all over again the
  # moment the check has an answer. The copy with no version in its output is the
  # one that makes that visible, because that same text is a settled failure once
  # every copy answers, so a record that forgot it speaks again.
  home=$(make_home twin-dead-ends)
  mute="$TMP_ROOT/twin-dead-ends/mute/bin"
  hung="$TMP_ROOT/twin-dead-ends/hung/bin"
  make_copy "$mute" "$TOOL" 'no version here'
  make_slow_copy "$hung" "$TOOL" 30
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$mute:$hung")

  run_check_until_unanswered "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "herdr check failed: $mute/$TOOL did not report a version" "the copy that reported no version was dropped from the report, so only one dead end of the sweep was said"
  assert_contains "$report" "$hung/$TOOL did not answer in time" "the hung copy was not reported once the streak ran out"

  entries=$(grep -o "$mute/$TOOL did not report a version" "$home/state/.tool-updates" | wc -l | tr -d ' ')
  [ "$entries" = 1 ] \
    || fail "the sweep said the copy reported no version but left $entries record entries for it instead of one"
  entries=$(grep -o "$hung/$TOOL did not answer in time" "$home/state/.tool-updates" | wc -l | tr -d ' ')
  [ "$entries" = 1 ] \
    || fail "the sweep said the copy never answered but left $entries record entries for it instead of one"

  # Both were said, so neither is news again. The hung copy answers from here on,
  # which gives the check an answer and turns the other copy's missing version into
  # a settled failure - the sweep that repeats it if the record kept only one of
  # the two findings this check reached.
  make_copy "$hung" "$TOOL" 'herdr 0.8.2'
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  [ ! -s "$out" ] \
    || fail "a dead end the sweep had already reported was reported again once the check answered: $(cat "$out")"
  pass "two dead ends in one sweep are each reported once"
}

test_a_failure_held_back_as_unanswered_is_reported_once_the_check_answers() {
  local home first second out path
  # A finding the streak gate held back was never shown, so it must not pass for
  # something the operator has already been told. Here the same text is no answer on
  # one sweep and a conclusion on the next, once every copy answers: that is the
  # sweep that has to report it.
  home=$(make_home held-back)
  first="$TMP_ROOT/held-back/first/bin"
  second="$TMP_ROOT/held-back/second/bin"
  make_copy "$first" "$TOOL" 'no version here'
  make_killed_copy "$second" "$TOOL"
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$second")

  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "a sweep that heard from no copy at all spoke on its own: $(cat "$out")"

  make_copy "$second" "$TOOL" 'herdr 0.8.2'
  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr check failed: $first/$TOOL did not report a version" "the failure the sweep had held back was never reported once the check answered"
  pass "a failure held back as unanswered is reported once its check answers"
}

test_a_sweep_with_no_answer_keeps_a_failure_the_probe_answered() {
  local home first mute out path
  # A copy that answers without a version is a conclusion the probe reached, and
  # a later sweep that gets no answer at all says nothing about it. Only the one
  # unanswered entry a check leaves behind is capped, so the answered failure must
  # still be remembered afterwards rather than evicted by it and reported again.
  home=$(make_home sibling-failure)
  first="$TMP_ROOT/sibling-failure/first/bin"
  mute="$TMP_ROOT/sibling-failure/mute/bin"
  make_copy "$first" "$TOOL" 'herdr 0.8.0'
  make_copy "$mute" "$TOOL" 'no version here'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$mute")

  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "herdr check failed: $mute/$TOOL did not report a version" "the copy that answered without a version was not reported"

  # The first copy now stalls, so this sweep gets no answer from it and never
  # reaches the second copy's failure to report it again.
  make_slow_copy "$first" "$TOOL" 30
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_not_contains "$(cat "$out")" "$mute/$TOOL" "a sweep that never asked the second copy reported its failure anyway"

  make_copy "$first" "$TOOL" 'herdr 0.8.0'
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  [ ! -s "$out" ] || fail "a sweep with no answer evicted the failure the probe had answered, so it was reported again: $(cat "$out")"
  pass "a sweep with no answer keeps the failure a probe of the same check answered"
}

test_a_cut_short_command_check_reports_no_update() {
  local home first mute last out path entries
  # A command check that did not hear from every copy cannot say which copy is
  # newest, so it reports no update from that comparison at all. That is also what
  # keeps its record bounded: were it to report one anyway, every sweep whose copies
  # kept changing would leave another remembered update behind.
  home=$(make_home cut-short-quiet)
  first="$TMP_ROOT/cut-short-quiet/mise/installs/herdr/latest/bin"
  mute="$TMP_ROOT/cut-short-quiet/mute/bin"
  last="$TMP_ROOT/cut-short-quiet/local/bin"
  make_copy "$first" "$TOOL" 'herdr 0.8.0'
  make_copy "$mute" "$TOOL" 'herdr 0.8.1'
  make_copy "$last" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$mute:$last")

  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "herdr update not in effect" "the first sweep did not report the PATH skew"

  # One copy stalls from here on, while the newest copy keeps being upgraded, so
  # every sweep would have a different skew to report if it reported one.
  make_slow_copy "$mute" "$TOOL" 30
  make_copy "$last" "$TOOL" 'herdr 0.8.3'
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_not_contains "$(cat "$out")" "update not in effect" "a check that never heard from every copy claimed to know the skew"

  make_copy "$last" "$TOOL" 'herdr 0.8.4'
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_not_contains "$(cat "$out")" "update not in effect" "a check that never heard from every copy claimed to know the skew"

  # state/.tool-updates is this check's own record of what it already reported.
  entries=$(grep -o 'update not in effect' "$home/state/.tool-updates" | wc -l | tr -d ' ')
  [ "$entries" = 1 ] \
    || fail "two sweeps that never heard from every copy left $entries remembered updates behind instead of the one already reported"
  pass "a command check cut short reports no update, and remembers no new one"
}

test_a_copy_cut_short_after_printing_a_version_is_still_reported() {
  local home first last out path
  # A copy can print what looks like a whole version and then hang, so its probe is
  # cut short with that text already captured. Reading a version out of it would
  # credit the copy with an answer it never finished, and would leave nothing at all
  # to report: the skew is withheld from an incomplete comparison, so if that copy
  # also counted as answered the check would go silent with no way back. It must say
  # it had no answer from that copy instead.
  home=$(make_home cut-after-printing)
  first="$TMP_ROOT/cut-after-printing/mise/installs/herdr/latest/bin"
  last="$TMP_ROOT/cut-after-printing/local/bin"
  make_copy "$first" "$TOOL" 'herdr 0.8.0'
  make_hanging_copy "$last" "$TOOL" 'herdr 0.9.0' 30
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$last")

  run_check_until_unanswered "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  assert_contains "$(cat "$out")" "herdr check failed: $last/$TOOL did not answer in time" "the copy that was cut short after printing was never reported, so the check went silent"
  assert_not_contains "$(cat "$out")" "update not in effect" "a check that never heard a copy out claimed to know the skew"
  pass "a copy cut short after printing a version is reported, not read as an answer"
}

test_a_copy_killed_before_it_answered_keeps_what_it_reported() {
  local home stale fresh out path
  # A probe can be cut short by a signal instead of by its own bound, which the
  # bounded runner reports as 128 plus the signal rather than as its timeout
  # status. Either way the copy answered nothing, so it must not settle the
  # command check and clear the skew already reported.
  home=$(make_home killed-copy)
  stale="$TMP_ROOT/killed-copy/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/killed-copy/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$stale:$fresh")

  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr update not in effect" "the first sweep did not report the PATH skew"

  make_killed_copy "$stale" "$TOOL"
  run_check_until_unanswered "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr check failed: $stale/$TOOL did not answer in time" "a copy killed before it answered was not reported"

  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "a copy killed before it answered erased the skew already reported, so it was reported again: $(cat "$out")"
  pass "a copy killed before it answered keeps what its tool's command check reported"
}

test_the_record_is_written_under_the_system_shell() {
  local home stale fresh out path status report
  # The record is built from arrays, and an empty array expanded with [@] under
  # `set -u` is a fatal unbound variable on Bash 3.2, which is still the stock
  # /bin/bash on macOS. That killed the write on the first sweep with a finding,
  # left the record empty, and made every later poll report the same update
  # again, so this case runs the check under the system shell rather than
  # whatever bash runs this suite.
  if [ ! -x /bin/bash ]; then
    pass "the system shell case is skipped without /bin/bash"
    return
  fi
  home=$(make_home system-shell)
  stale="$TMP_ROOT/system-shell/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/system-shell/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$stale:$fresh")

  status=0
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" PATH="$path" FM_TOOL_UPDATE_INTERVAL=0 \
    /bin/bash "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "system shell first sweep exit"
  report=$(cat "$out")
  assert_contains "$report" "herdr update not in effect" "the system shell sweep did not report the PATH skew"
  assert_not_contains "$report" "unbound variable" "the system shell sweep tripped over an empty array"

  status=0
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" PATH="$path" FM_TOOL_UPDATE_INTERVAL=0 \
    /bin/bash "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "system shell second sweep exit"
  [ ! -s "$out" ] || fail "the system shell could not record its first sweep, so the same update was reported again: $(cat "$out")"
  pass "the report record is written under the system shell as well"
}

test_one_failing_check_kind_keeps_what_the_other_kind_reported() {
  local home work stale fresh dir out path report
  # A tool watched through both a command and a git remote has two independent
  # checks. An unanswered remote says nothing about what the command probe found,
  # and nothing about the git update that was already reported either, so the
  # command probe still answering must not be read as a sweep that settled the
  # tool and cleared its git memory.
  home=$(make_home mixed)
  work=$(git_fixture mixed-repo)
  git -C "$work" reset -q --hard HEAD~2
  stale="$TMP_ROOT/mixed/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/mixed/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'

  # A git whose network read stalls whenever the flag file exists.
  dir="$TMP_ROOT/mixed/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
if [ -e '$TMP_ROOT/mixed/offline' ]; then
  for arg in "\$@"; do
    if [ "\$arg" = ls-remote ]; then
      sleep 30
      exit 0
    fi
  done
fi
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"
  path=$(fixture_path "$dir:$stale:$fresh")

  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  report=$(cat "$out")
  assert_contains "$report" "herdr update not in effect" "the first sweep did not report the PATH skew"
  assert_contains "$report" "herdr update available: local main is 2 commits behind origin/main" "the first sweep did not report the pending git update"

  touch "$TMP_ROOT/mixed/offline"
  run_check_until_unanswered "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  report=$(cat "$out")
  assert_contains "$report" "herdr check failed: origin did not answer" "the unanswered read was not reported"
  assert_not_contains "$report" "update available" "an unanswered read reported an update it never established"

  rm -f "$TMP_ROOT/mixed/offline"
  run_check "$home" "$path" "$out" FM_TOOL_UPDATE_PROBE_SECS=2
  [ ! -s "$out" ] || fail "a git update already reported came back because the command probe of the same tool still answered: $(cat "$out")"
  pass "one kind of check failing keeps what the other kind of the same tool reported"
}

test_a_marginal_sweep_budget_does_not_wake_on_every_other_poll() {
  local home first second out path i
  # A host whose sweep budget only sometimes suffices is the same flap as a
  # flaky remote, one level up: the sweep that ran out of time established
  # nothing the operator can act on, so it waits for its own three-sweep streak
  # instead of speaking every time it happens.
  home=$(make_home marginal)
  first="$TMP_ROOT/marginal/first/bin"
  second="$TMP_ROOT/marginal/second/bin"
  make_copy "$first" "$TOOL-a" 'first 1.0.0'
  make_copy "$second" "$TOOL-b" 'second 2.0.0'
  write_config "$home" "{\"tools\":[{\"name\":\"first\",\"command\":\"$TOOL-a\"},{\"name\":\"second\",\"command\":\"$TOOL-b\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$second")

  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "the baseline sweep had something to report: $(cat "$out")"

  for i in 1 2; do
    # The first tool hangs, so the budget is gone before the second tool is
    # reached, and then it answers again on the next poll.
    make_slow_copy "$first" "$TOOL-a" 30
    run_check "$home" "$path" "$out" FM_TOOL_UPDATE_BUDGET_SECS=1
    [ ! -s "$out" ] || fail "sweep $i that ran out of time woke the operator on its own: $(cat "$out")"
    make_copy "$first" "$TOOL-a" 'first 1.0.0'
    run_check "$home" "$path" "$out"
    [ ! -s "$out" ] || fail "the sweep after truncated sweep $i reported something: $(cat "$out")"
  done
  pass "a sweep budget that only sometimes runs out does not wake the operator every other poll"
}

test_a_budget_that_ends_the_copy_loop_reports_no_update() {
  local home out path dirs dir i version
  # A copy loop can also be cut short by the sweep budget rather than by a probe
  # bound: the copies after the cut are never asked at all, so the newest one on
  # PATH may be among them and the comparison is just as incomplete. No update may
  # be reported from it.
  home=$(make_home loop-budget)
  path=
  dirs=
  for i in 1 2 3 4 5 6; do
    dir="$TMP_ROOT/loop-budget/copy-$i/bin"
    mkdir -p "$dir"
    # Every copy answers well inside its own bound, so none of them times out;
    # together they outlast the sweep budget, which is what ends the loop.
    version=0.8.$i
    [ "$i" != 6 ] || version=0.9.0
    cat > "$dir/$TOOL" <<SH
#!/usr/bin/env bash
sleep 0.4
printf 'herdr $version\n'
SH
    chmod 0755 "$dir/$TOOL"
    dirs="${dirs:+$dirs:}$dir"
  done
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$dirs")

  # The report of the streak's last sweep names the tool the sweep never finished,
  # which is what proves the budget ended the loop rather than a probe bound.
  run_check_until_unanswered "$home" "$path" "$out" FM_TOOL_UPDATE_BUDGET_SECS=1 FM_TOOL_UPDATE_PROBE_SECS=5
  assert_contains "$(cat "$out")" "herdr check failed: the time budget ran out before every copy answered" "the budget did not end the copy loop, so this case proves nothing"
  assert_not_contains "$(cat "$out")" "update not in effect" "a loop the budget ended claimed to know the newest copy on PATH"
  assert_not_contains "$(cat "$out")" "update available" "a loop the budget ended claimed to know an available update"
  pass "a copy loop the sweep budget ended reports no update from its incomplete comparison"
}

test_a_truncated_sweep_keeps_what_the_tools_it_missed_reported() {
  local home first stale fresh out path
  # A sweep that runs out of budget never reaches the tools after the cut, which
  # says nothing about what they last reported. Forgetting them there would make
  # their still-pending updates news again on the next full sweep, which is the
  # repeat this record exists to prevent.
  home=$(make_home truncated)
  first="$TMP_ROOT/truncated/first/bin"
  stale="$TMP_ROOT/truncated/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/truncated/local/bin"
  make_copy "$first" "$TOOL-a" 'first 1.0.0'
  make_copy "$stale" "$TOOL-b" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL-b" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"first\",\"command\":\"$TOOL-a\"},{\"name\":\"herdr\",\"command\":\"$TOOL-b\"}]}"
  out="$home/out.txt"
  path=$(fixture_path "$first:$stale:$fresh")

  run_check "$home" "$path" "$out"
  assert_contains "$(cat "$out")" "herdr update not in effect" "the first sweep did not report the PATH skew"

  # The first tool now hangs and spends the whole budget, so the second tool is
  # never reached.
  make_slow_copy "$first" "$TOOL-a" 30
  run_check_until_unanswered "$home" "$path" "$out" FM_TOOL_UPDATE_BUDGET_SECS=1
  assert_contains "$(cat "$out")" "check incomplete: the time budget ran out before herdr" "the truncated sweep did not say which tool it never reached"

  make_copy "$first" "$TOOL-a" 'first 1.0.0'
  run_check "$home" "$path" "$out"
  [ ! -s "$out" ] || fail "a sweep that ran out of budget forgot a tool it never reached, so its update was reported again: $(cat "$out")"
  pass "a sweep truncated by its budget keeps what the tools it never reached reported"
}

test_an_overlong_report_says_it_was_cut() {
  local home out report i tools_json=
  # Many watched tools can outgrow one line. The report must say it was cut
  # rather than end mid-finding as if that were everything found.
  home=$(make_home long)
  for i in $(seq 1 30); do
    [ -z "$tools_json" ] || tools_json="$tools_json,"
    tools_json="$tools_json{\"name\":\"absent-tool-$i\",\"command\":\"fm-absent-fixture-$i\"}"
  done
  write_config "$home" "{\"tools\":[$tools_json]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  report=$(cat "$out")
  assert_contains "$report" "[truncated]" "an over-long report was cut without saying so"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the cut report must still be exactly one line"
  pass "an over-long report is cut with the shared truncation marker"
}

test_a_finding_past_the_cut_is_still_reported() {
  local home stale fresh out report i tools_json=
  # Once a report is long enough to be cut, a new finding lands past the cut and
  # leaves the printed line unchanged. It still has to count as news, or the PATH
  # skew this check exists for would be suppressed for good on a busy home.
  home=$(make_home past-cut)
  stale="$TMP_ROOT/past-cut/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/past-cut/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  for i in $(seq 1 30); do
    [ -z "$tools_json" ] || tools_json="$tools_json,"
    tools_json="$tools_json{\"name\":\"absent-tool-$i\",\"command\":\"fm-absent-fixture-$i\"}"
  done
  out="$home/out.txt"
  write_config "$home" "{\"tools\":[$tools_json]}"
  run_check "$home" "$(fixture_path "$stale:$fresh")" "$out"
  assert_contains "$(cat "$out")" "[truncated]" "the first report was not long enough to be cut, so this case proves nothing"

  # The skew tool goes last, so its finding falls past the cut and the printed
  # line is byte identical to the one the first sweep already recorded.
  write_config "$home" "{\"tools\":[$tools_json,{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  run_check "$home" "$(fixture_path "$stale:$fresh")" "$out"
  report=$(cat "$out")
  [ -n "$report" ] || fail "a finding past the cut produced no report at all, so it can never reach the watcher"
  assert_contains "$report" "[truncated]" "the second report was not cut, so the finding was not past the cut"
  pass "a finding that lands past the cut is still reported as news"
}

test_probes_are_skipped_between_intervals() {
  local home dir out status now
  home=$(make_home cadence)
  dir="$TMP_ROOT/cadence/bin"
  make_copy "$dir" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  now=1700000000

  status=0
  FM_HOME="$home" PATH="$(fixture_path "$dir")" FM_CHECK_TIMEOUT=30 FM_TOOL_UPDATE_INTERVAL=900 FM_TOOL_UPDATE_NOW="$now" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "first cadence run exit"
  assert_grep 'fm-tool-updates-v5' "$home/state/.tool-updates" "the first run did not record its sweep"

  # A finding appears, but the interval has not elapsed, so no probe runs.
  make_copy "$dir" "$TOOL" 'no version here'
  status=0
  FM_HOME="$home" PATH="$(fixture_path "$dir")" FM_CHECK_TIMEOUT=30 FM_TOOL_UPDATE_INTERVAL=900 FM_TOOL_UPDATE_NOW="$((now + 300))" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "gated cadence run exit"
  [ ! -s "$out" ] || fail "a run inside the interval probed and spoke: $(cat "$out")"

  status=0
  FM_HOME="$home" PATH="$(fixture_path "$dir")" FM_CHECK_TIMEOUT=30 FM_TOOL_UPDATE_INTERVAL=900 FM_TOOL_UPDATE_NOW="$((now + 901))" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "due cadence run exit"
  assert_contains "$(cat "$out")" "did not report a version" "the run after the interval did not probe"
  pass "probes run once per interval, not on every poll"
}

test_an_oversized_budget_is_cut_to_fit_and_reported() {
  local home stale fresh out report status
  # A sweep budget larger than the watcher's own per check bound lets the watcher
  # kill the run, which prints nothing and records nothing, so the same silence
  # repeats on every poll. Cutting it keeps the detector alive, and the cut is
  # reported so the operator can see the setting was not used as written.
  home=$(make_home budget-cut)
  stale="$TMP_ROOT/budget-cut/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/budget-cut/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$stale:$fresh")" FM_TOOL_UPDATE_INTERVAL=0 \
    FM_TOOL_UPDATE_BUDGET_SECS=60 FM_CHECK_TIMEOUT=30 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "oversized budget exit"
  report=$(cat "$out")
  # The cut leaves room for the whole-second rounding and the kill grace as well
  # as one probe bound, so a cut sweep really does end before the watcher bound.
  assert_contains "$report" "sweep budget 60s cut to 27s to stay inside the watcher check timeout of 30s" "a budget that cannot fit the watcher bound was not cut and reported"
  assert_contains "$report" "herdr update not in effect" "the detector went quiet instead of sweeping with the cut budget"

  # The default budget of 20s fits the default bound, so it is used as written.
  # The record is cleared first because the no-nag gate would otherwise suppress
  # this run, whose bare skew line differs from the cut run's line above.
  rm -f "$home/state/.tool-updates"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$stale:$fresh")" FM_TOOL_UPDATE_INTERVAL=0 \
    FM_CHECK_TIMEOUT=30 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "default budget exit"
  report=$(cat "$out")
  assert_not_contains "$report" "sweep budget" "the default budget was cut at the default watcher bound"
  assert_contains "$report" "herdr update not in effect" "the sweep stopped reporting with the default budget"

  # A budget the watcher bound has room for is used as written. The cleared
  # record keeps the no-nag gate from hiding this run's repeat of the same line.
  rm -f "$home/state/.tool-updates"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$stale:$fresh")" FM_TOOL_UPDATE_INTERVAL=0 \
    FM_TOOL_UPDATE_BUDGET_SECS=60 FM_CHECK_TIMEOUT=120 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "fitting budget exit"
  report=$(cat "$out")
  assert_not_contains "$report" "sweep budget" "a budget that fits the watcher bound was cut anyway"
  assert_contains "$report" "herdr update not in effect" "the sweep stopped reporting with a budget that fits"
  pass "a budget that cannot fit the watcher bound is cut and reported, and the sweep keeps working"
}

test_invalid_environment_and_action_refuse() {
  local home status
  home=$(make_home refuse)
  status=0
  FM_HOME="$home" FM_TOOL_UPDATE_INTERVAL=5 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "too-small interval exit"
  status=0
  FM_HOME="$home" FM_TOOL_UPDATE_PROBE_SECS=0 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "zero probe bound exit"
  status=0
  FM_HOME="$home" FM_TOOL_UPDATE_BUDGET_SECS=999 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "oversized budget exit"
  status=0
  FM_HOME="$home" "$CHECK" sweep >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown action exit"
  status=0
  FM_HOME="$home" "$CHECK" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "help exit"
  pass "an out of range bound or unknown action refuses instead of guessing"
}

# --- arming through the existing watcher contract ----------------------------

test_arm_registers_the_check_and_disarm_removes_it() {
  local home dir status
  home=$(make_home arm)
  dir="$TMP_ROOT/arm/bin"
  make_copy "$dir" "$TOOL" 'herdr 0.8.2'
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm without a registry exit"
  assert_absent "$home/state/tool-updates.check.sh" "arm wrote a check shim without a registry"

  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/tool-updates.check.sh" "arm did not write the check shim"
  assert_present "$home/state/tool-updates.check-trust" "arm did not register the check's bytes"
  [ "$(stat -c %a "$home/state/tool-updates.check.sh" 2>/dev/null || stat -f %Lp "$home/state/tool-updates.check.sh")" = 700 ] \
    || fail "the check shim is not mode 700"
  assert_grep 'fm-custom-check-v1' "$home/state/tool-updates.check-trust" "the trust binding has the wrong schema"

  # Arming twice must stay valid rather than invalidating its own binding.
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arming twice failed"
  assert_grep 'fm-custom-check-v1' "$home/state/tool-updates.check-trust" "re-arming lost the trust binding"

  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/tool-updates.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/tool-updates.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.tool-updates" "disarm left the report record behind"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home dir target mode status
  # A stale or hostile symlink at the shim path must be refused rather than
  # followed: following it would write the shim body into a file someone else
  # owns and then make that file executable.
  home=$(make_home arm-symlink)
  dir="$TMP_ROOT/arm-symlink/bin"
  make_copy "$dir" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  target="$TMP_ROOT/arm-symlink/not-the-shim.txt"
  printf 'a file the shim must not touch\n' > "$target"
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
  ln -s "$target" "$home/state/tool-updates.check.sh"

  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over a symlink exit"
  [ "$(cat "$target")" = 'a file the shim must not touch' ] || fail "arm followed the symlink and overwrote its target"
  [ "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" = "$mode" ] || fail "arm changed the mode of the symlink's target"
  assert_absent "$home/state/tool-updates.check-trust" "arm registered a shim it refused to write"
  pass "a symlink at the shim path is refused instead of followed"
}

test_a_failed_registration_leaves_no_unregistered_shim() {
  local home dir target stale_shim status
  # An unregistered shim in state/ is not inert: the watcher rejects it every
  # cycle and wakes firstmate about unauthenticated state checks until someone
  # deletes it by hand. So a home that could not be armed has to come back to the
  # state it was in, and arm still has to say it failed.
  home=$(make_home arm-register-fail)
  dir="$TMP_ROOT/arm-register-fail/bin"
  make_copy "$dir" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  # A symlink at the trust path makes registration refuse, which is the shape any
  # register failure has from arm's side.
  target="$TMP_ROOT/arm-register-fail/not-the-trust.txt"
  printf 'a file the trust binding must not touch\n' > "$target"
  ln -s "$target" "$home/state/tool-updates.check-trust"

  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with an unusable trust path exit"
  assert_absent "$home/state/tool-updates.check.sh" "a failed registration left an unregistered check shim behind"
  [ "$(cat "$target")" = 'a file the trust binding must not touch' ] || fail "arm wrote through the trust symlink"

  # A shim that was already there is only kept when its trust binding is still
  # intact. Here the binding is unusable, so putting the old bytes back would
  # leave exactly the unbound shim the watcher wakes about, and the home has to
  # end plainly not armed instead.
  stale_shim="$TMP_ROOT/arm-register-fail/shim-armed-earlier"
  printf '#!/usr/bin/env bash\n# a shim armed earlier\nexit 0\n' > "$stale_shim"
  cp "$stale_shim" "$home/state/tool-updates.check.sh"
  chmod 0700 "$home/state/tool-updates.check.sh"
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over an existing shim with an unusable trust path exit"
  assert_absent "$home/state/tool-updates.check.sh" "a failed arm left a shim behind that no trust binding covers"
  pass "a failed registration never leaves a shim without a matching trust binding"
}

test_a_failed_rearm_leaves_no_shim_the_trust_binding_lost() {
  local home dir fake status
  # The register removes an existing trust binding when its own post-write check
  # fails, so an arm that fails there would leave a home that WAS armed holding a
  # shim with no binding, which the watcher rejects on every cycle. The home must
  # end plainly not armed instead.
  home=$(make_home arm-rearm-fail)
  dir="$TMP_ROOT/arm-rearm-fail/bin"
  make_copy "$dir" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "the first arm failed"
  assert_present "$home/state/tool-updates.check-trust" "the first arm did not bind the shim"

  # A hash tool that answers with nothing makes the register write a binding it
  # then rejects, and it removes the old binding on the way out.
  fake="$TMP_ROOT/arm-rearm-fail/fake-hash"
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/shasum"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/sha256sum"
  chmod 0755 "$fake/shasum" "$fake/sha256sum"
  printf '#!/usr/bin/env bash\n# a shim armed earlier\nexit 0\n' > "$home/state/tool-updates.check.sh"
  chmod 0700 "$home/state/tool-updates.check.sh"

  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$fake")" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm whose registration cannot hash exit"
  assert_absent "$home/state/tool-updates.check.sh" "a failed re-arm left a shim behind after the trust binding was removed"
  assert_absent "$home/state/tool-updates.check-trust" "the failed registration left a trust binding behind"
  pass "a re-arm that loses the trust binding leaves no shim behind"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home stale fresh out status
  # The watcher runs the shim from its own working directory, so a relative home
  # has to be resolved before it is persisted. Otherwise the shim reads whatever
  # sits under the watcher's directory, finds no registry, and stays silent for
  # good.
  home=$(make_home arm-relative)
  stale="$TMP_ROOT/arm-relative/mise/bin"
  fresh="$TMP_ROOT/arm-relative/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"

  status=0
  (cd "$TMP_ROOT" && FM_HOME=arm-relative "$CHECK" arm >/dev/null 2>&1) || status=$?
  expect_code 0 "$status" "arm with a relative home exit"

  out="$home/out.txt"
  status=0
  (cd / && env -u FM_HOME PATH="$(fixture_path "$stale:$fresh")" FM_CHECK_TIMEOUT=30 FM_TOOL_UPDATE_INTERVAL=0 \
    "$home/state/tool-updates.check.sh" >"$out" 2>&1) || status=$?
  expect_code 0 "$status" "shim run from another directory exit"
  assert_contains "$(cat "$out")" "herdr update not in effect" "the shim read a different home than the one it was armed for"
  pass "a relative home is resolved before it is persisted into the shim"
}

test_armed_check_wakes_the_watcher_with_the_skew_report() {
  local home stale fresh out err status
  # End to end through the real watcher: the armed check must reach it as a
  # `check:` wake carrying the same PATH skew line, with no new machinery.
  home=$(make_home wake)
  stale="$TMP_ROOT/wake/mise/installs/herdr/latest/bin"
  fresh="$TMP_ROOT/wake/local/bin"
  make_copy "$stale" "$TOOL" 'herdr 0.8.0'
  make_copy "$fresh" "$TOOL" 'herdr 0.8.2'
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not arm the watched tool check"

  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$stale:$fresh")" FM_CHECK_TIMEOUT=30 FM_TOOL_UPDATE_INTERVAL=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "tool updates: herdr update not in effect" "the wake did not carry the PATH skew report"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

test_path_skew_is_reported_from_every_copy
test_newest_copy_first_on_path_is_silent
test_identical_versions_are_silent
test_one_copy_reached_twice_is_probed_once
test_unreadable_version_is_a_failure_not_a_pass
test_missing_command_is_reported
test_announced_update_is_reported_from_the_tool_itself
test_announced_update_already_installed_is_not_double_reported
test_announced_update_newer_than_installed_is_still_reported
test_announcement_is_read_from_a_second_command
test_unusable_announce_pattern_is_reported_not_read_as_silence
test_one_broken_pattern_does_not_blind_the_rest_of_the_sweep
test_an_unchecked_announcement_source_is_not_read_as_current
test_an_announcement_probe_that_does_not_answer_is_reported
test_an_unanswered_announcement_withholds_the_skew_it_never_established
test_quiet_tool_with_announce_pattern_is_silent
test_commits_behind_origin_are_reported
test_default_branch_is_detected_when_branch_is_omitted
test_default_branch_is_asked_of_the_remote_when_the_clone_has_no_record
test_current_and_ahead_repositories_are_silent
test_unusable_git_source_is_reported
test_unreadable_remote_is_not_reported_as_a_missing_branch
test_missing_branch_on_a_readable_remote_is_still_reported
test_git_probes_stop_when_the_sweep_budget_is_gone
test_a_git_probe_that_does_not_answer_is_not_an_update
test_a_stalled_repository_probe_is_not_reported_as_not_a_repository
test_absent_registry_is_silent
test_malformed_registry_is_reported_not_ignored
test_findings_are_reported_once_until_they_change
test_a_flaky_remote_does_not_repeat_a_reported_update
test_a_remote_that_stays_unreachable_is_reported_once
test_an_unreachable_remote_keeps_the_update_when_the_branch_comes_from_the_remote
test_a_failure_the_probe_answered_does_not_swallow_a_returning_finding
test_a_copy_that_never_answered_keeps_what_it_reported
test_a_copy_killed_before_it_answered_keeps_what_it_reported
test_a_copy_cut_short_after_printing_a_version_is_still_reported
test_a_sweep_with_no_answer_keeps_a_failure_the_probe_answered
test_a_failure_held_back_as_unanswered_is_reported_once_the_check_answers
test_two_dead_ends_in_one_sweep_are_reported_once_each
test_a_cut_short_command_check_reports_no_update
test_a_later_copy_cut_short_keeps_what_the_command_check_reported
test_repeated_unanswered_sweeps_keep_one_failure_per_check
test_the_record_is_written_under_the_system_shell
test_one_failing_check_kind_keeps_what_the_other_kind_reported
test_a_truncated_sweep_keeps_what_the_tools_it_missed_reported
test_a_marginal_sweep_budget_does_not_wake_on_every_other_poll
test_a_budget_that_ends_the_copy_loop_reports_no_update
test_an_overlong_report_says_it_was_cut
test_a_finding_past_the_cut_is_still_reported
test_probes_are_skipped_between_intervals
test_an_oversized_budget_is_cut_to_fit_and_reported
test_invalid_environment_and_action_refuse
test_arm_registers_the_check_and_disarm_removes_it
test_arm_refuses_a_symlink_at_the_shim_path
test_a_failed_registration_leaves_no_unregistered_shim
test_a_failed_rearm_leaves_no_shim_the_trust_binding_lost
test_arm_resolves_a_relative_home_into_the_shim
test_armed_check_wakes_the_watcher_with_the_skew_report
