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

write_config() {
  local home=$1
  shift
  printf '%s\n' "$*" > "$home/config/watched-tools.json"
}

# Only the fixture directories, plus the directories the check itself needs, so
# a real tool of the same name on the captain's PATH can never join the fixture.
fixture_path() {
  printf '%s:%s\n' "$1" "$PATH"
}

run_check() {
  local home=$1 path=$2 out=$3
  shift 3
  local status=0
  env "$@" FM_HOME="$home" PATH="$path" FM_TOOL_UPDATE_INTERVAL=0 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
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
  [ "$(wc -l < "$out")" = 1 ] || fail "the report must be exactly one line for the wake record"
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

test_one_copy_reached_twice_is_not_skew() {
  local home dir link out
  # A single install reachable through two PATH entries must not read as two
  # installs, or a symlinked bin directory would report skew against itself.
  home=$(make_home one-copy)
  dir="$TMP_ROOT/one-copy/real/bin"
  link="$TMP_ROOT/one-copy/linked-bin"
  make_copy "$dir" "$TOOL" 'herdr 0.8.2'
  ln -s "$dir" "$link"
  write_config "$home" "{\"tools\":[{\"name\":\"herdr\",\"command\":\"$TOOL\"}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir:$link")" "$out"
  [ ! -s "$out" ] || fail "one copy reached through two PATH entries reported a finding: $(cat "$out")"
  pass "one copy reached through two PATH entries is one install"
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
  fm_git_identity
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
  git -C "$work" reset -q --hard HEAD~1
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
  assert_absent "$work/.git/refs/remotes/origin/HEAD" "the fixture still records the remote's default branch locally"
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

test_an_overlong_report_says_it_was_cut() {
  local home out report i tools=
  # Many watched tools can outgrow one line. The report must say it was cut
  # rather than end mid-finding as if that were everything found.
  home=$(make_home long)
  for i in $(seq 1 30); do
    [ -z "$tools" ] || tools="$tools,"
    tools="$tools{\"name\":\"absent-tool-$i\",\"command\":\"fm-absent-fixture-$i\"}"
  done
  write_config "$home" "{\"tools\":[$tools]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  report=$(cat "$out")
  assert_contains "$report" "[truncated]" "an over-long report was cut without saying so"
  [ "$(wc -l < "$out")" = 1 ] || fail "the cut report must still be exactly one line"
  pass "an over-long report is cut with the shared truncation marker"
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
  FM_HOME="$home" PATH="$(fixture_path "$dir")" FM_TOOL_UPDATE_INTERVAL=900 FM_TOOL_UPDATE_NOW="$now" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "first cadence run exit"
  assert_grep 'fm-tool-updates-v1' "$home/state/.tool-updates" "the first run did not record its sweep"

  # A finding appears, but the interval has not elapsed, so no probe runs.
  make_copy "$dir" "$TOOL" 'no version here'
  status=0
  FM_HOME="$home" PATH="$(fixture_path "$dir")" FM_TOOL_UPDATE_INTERVAL=900 FM_TOOL_UPDATE_NOW="$((now + 300))" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "gated cadence run exit"
  [ ! -s "$out" ] || fail "a run inside the interval probed and spoke: $(cat "$out")"

  status=0
  FM_HOME="$home" PATH="$(fixture_path "$dir")" FM_TOOL_UPDATE_INTERVAL=900 FM_TOOL_UPDATE_NOW="$((now + 901))" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "due cadence run exit"
  assert_contains "$(cat "$out")" "did not report a version" "the run after the interval did not probe"
  pass "probes run once per interval, not on every poll"
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
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not arm the watched tool check"

  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$stale:$fresh")" FM_TOOL_UPDATE_INTERVAL=0 \
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
test_one_copy_reached_twice_is_not_skew
test_unreadable_version_is_a_failure_not_a_pass
test_missing_command_is_reported
test_announced_update_is_reported_from_the_tool_itself
test_announcement_is_read_from_a_second_command
test_quiet_tool_with_announce_pattern_is_silent
test_commits_behind_origin_are_reported
test_default_branch_is_detected_when_branch_is_omitted
test_default_branch_is_asked_of_the_remote_when_the_clone_has_no_record
test_current_and_ahead_repositories_are_silent
test_unusable_git_source_is_reported
test_absent_registry_is_silent
test_malformed_registry_is_reported_not_ignored
test_findings_are_reported_once_until_they_change
test_an_overlong_report_says_it_was_cut
test_probes_are_skipped_between_intervals
test_invalid_environment_and_action_refuse
test_arm_registers_the_check_and_disarm_removes_it
test_armed_check_wakes_the_watcher_with_the_skew_report
