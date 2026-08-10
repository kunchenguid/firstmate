#!/usr/bin/env bash
# Behavior tests for bin/fm-await-artifact.sh and the check it generates.
#
# The generated file is a program the watcher executes, so these tests drive it
# the way bin/fm-watch.sh does: from a private copy, with `bash <file>`, no
# arguments, and from an unrelated working directory. Acceptance is proven
# through bin/fm-check-lib.sh's own gate (the exact function the watcher calls)
# rather than by asserting on the generated source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

AWAIT="$ROOT/bin/fm-await-artifact.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-await-artifact)

# A fresh home with one live task and an artifact directory. Echoes the home.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/artifacts"
  fm_write_meta "$home/state/wait-1.meta" \
    "window=firstmate:fm-wait-1" \
    "endpoint_task_id=wait-1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$home"
}

arm() {  # <home> <args...>
  FM_HOME="$1" "$AWAIT" "${@:2}"
}

# Run the generated check exactly as bin/fm-watch.sh does: a private copy of the
# registered bytes, executed as `bash <copy>` with no arguments from a directory
# that is not the state dir. A check that depended on $0, on its own filename, or
# on the caller's cwd would fail here rather than only in production.
sweep() {  # <home>
  local home=$1 copy out
  copy=$(mktemp "$home/state/.fm-test-snapshot.XXXXXX")
  cp "$home/state/wait-1.check.sh" "$copy"
  out=$(cd "$TMP_ROOT" && bash "$copy" 2>/dev/null)
  rm -f "$copy"
  printf '%s' "$out"
}

test_help_includes_entire_header() {
  local out
  out=$("$AWAIT" --help)
  assert_contains "$out" "Usage: fm-await-artifact.sh" "help must print the usage line"
  assert_contains "$out" "mtime/size signature" "help must document the default readiness rule"
  assert_contains "$out" "REPLACES the stability heuristic" "help must document sentinel semantics"
  [ -z "$(bash -n "$AWAIT" 2>&1)" ] || fail "bash -n bin/fm-await-artifact.sh emitted output"
  pass "fm-await-artifact.sh: --help prints the header and the script parses"
}

test_silent_until_present_stable_then_fires_exactly_once() {
  local home out
  home=$(make_home stability)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null \
    || fail "stability: arming failed"

  out=$(sweep "$home")
  [ -z "$out" ] || fail "stability: check spoke while the artifact was absent (got: $out)"

  printf 'partial' > "$home/artifacts/report.md"
  out=$(sweep "$home")
  [ -z "$out" ] || fail "stability: check spoke on first sight of the artifact (got: $out)"

  # Growth within the same wall-clock second: only the size component of the
  # signature moves, which is exactly the half-written-report case.
  printf ' and more' >> "$home/artifacts/report.md"
  out=$(sweep "$home")
  [ -z "$out" ] || fail "stability: check spoke while the artifact was still growing (got: $out)"

  out=$(sweep "$home")
  assert_contains "$out" "artifact ready:" "stability: check must fire once the artifact is stable"
  assert_contains "$out" "$home/artifacts/report.md" "stability: the fired line must name the artifact"
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] \
    || fail "stability: check printed more than one line: $out"

  out=$(sweep "$home")
  [ -z "$out" ] || fail "stability: check fired a second time (got: $out)"
  pass "artifact wake stays silent until every path is present and stable, then fires exactly once"
}

# The existence and non-empty gates follow a symlink, so the signature must too.
# A link's own mtime and size never move while its target grows, which would
# announce a half-written report on the very next sweep.
test_symlinked_dependency_is_judged_by_its_target() {
  local home out
  home=$(make_home symlink)
  ln -s "$home/artifacts/report.md" "$home/artifacts/link.md"
  arm "$home" wait-1 "$home/artifacts/link.md" >/dev/null || fail "symlink: arming failed"

  printf 'partial' > "$home/artifacts/report.md"
  out=$(sweep "$home")
  [ -z "$out" ] || fail "symlink: check spoke on first sight of the artifact (got: $out)"

  printf ' and more' >> "$home/artifacts/report.md"
  out=$(sweep "$home")
  [ -z "$out" ] || fail "symlink: check spoke while the linked artifact was still growing (got: $out)"

  out=$(sweep "$home")
  assert_contains "$out" "artifact ready:" "symlink: check must fire once the linked artifact is stable"
  pass "a symlinked dependency is judged by its target's signature, not the link's"
}

test_empty_file_is_not_ready() {
  local home out
  home=$(make_home empty-file)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "empty-file: arming failed"
  : > "$home/artifacts/report.md"
  sweep "$home" >/dev/null
  out=$(sweep "$home")
  [ -z "$out" ] || fail "empty-file: an existing but empty artifact was announced (got: $out)"
  pass "an existing but empty artifact is never announced as ready"
}

test_every_path_must_be_ready() {
  local home out
  home=$(make_home two-paths)
  arm "$home" wait-1 "$home/artifacts/a.md" "$home/artifacts/b.md" >/dev/null \
    || fail "two-paths: arming failed"
  printf 'a\n' > "$home/artifacts/a.md"
  sweep "$home" >/dev/null
  out=$(sweep "$home")
  [ -z "$out" ] || fail "two-paths: check fired with one dependency still missing (got: $out)"

  printf 'b\n' > "$home/artifacts/b.md"
  sweep "$home" >/dev/null
  out=$(sweep "$home")
  assert_contains "$out" "artifact ready:" "two-paths: check must fire once both paths are ready"
  assert_contains "$out" "$home/artifacts/b.md" "two-paths: the fired line must name both artifacts"
  pass "a multi-path wait fires only when every dependency is ready"
}

test_sentinel_fires_on_the_marker_and_not_on_stability() {
  local home out
  home=$(make_home sentinel)
  arm "$home" wait-1 "$home/artifacts/report.md" --sentinel '<!-- final: zone-3 -->' >/dev/null \
    || fail "sentinel: arming failed"

  printf '# report\nzone 3 in progress\n' > "$home/artifacts/report.md"
  sweep "$home" >/dev/null
  out=$(sweep "$home")
  [ -z "$out" ] || fail "sentinel: an unmarked but stable report was announced (got: $out)"

  printf '%s\n' '<!-- final: zone-3 -->' >> "$home/artifacts/report.md"
  out=$(sweep "$home")
  assert_contains "$out" "artifact ready (sentinel):" "sentinel: check must fire on the marker"
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] \
    || fail "sentinel: check printed more than one line: $out"

  out=$(sweep "$home")
  [ -z "$out" ] || fail "sentinel: check fired a second time (got: $out)"
  pass "a sentinel wait fires on the producer's marker and never on stability alone"
}

test_sentinel_form_with_equals_and_rearming() {
  local home out
  home=$(make_home rearm)
  arm "$home" wait-1 "$home/artifacts/report.md" --sentinel='final: zone-1' >/dev/null \
    || fail "rearm: arming failed"
  printf 'body\n<!-- final: zone-1 -->\n' > "$home/artifacts/report.md"
  out=$(sweep "$home")
  assert_contains "$out" "artifact ready (sentinel):" "rearm: first section must wake firstmate"

  # Re-arming the same task for the next section replaces the spent check and
  # clears its fired record.
  arm "$home" wait-1 "$home/artifacts/report.md" --sentinel 'final: zone-2' >/dev/null \
    || fail "rearm: re-arming the same task failed"
  out=$(sweep "$home")
  [ -z "$out" ] || fail "rearm: re-armed check fired before the new section landed (got: $out)"
  printf '<!-- final: zone-2 -->\n' >> "$home/artifacts/report.md"
  out=$(sweep "$home")
  assert_contains "$out" "artifact ready (sentinel):" "rearm: second section must wake firstmate"
  pass "a per-section wait can be re-armed and each armed section fires once"
}

# The generated check must satisfy the real registration contract, not merely
# claim to. fm_custom_check_registered and fm_custom_check_snapshot_prepare are
# the exact gates bin/fm-watch.sh applies before executing a custom check.
test_generated_check_is_accepted_by_the_registration_contract() {
  local home mode links
  home=$(make_home accepted)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "accepted: arming failed"

  mode=$(fm_pr_file_mode "$home/state/wait-1.check.sh")
  [ "$mode" = 700 ] || fail "accepted: generated check mode is $mode, not 700"
  links=$(fm_pr_file_link_count "$home/state/wait-1.check.sh")
  [ "$links" = 1 ] || fail "accepted: generated check has $links links, not 1"
  [ ! -L "$home/state/wait-1.check.sh" ] || fail "accepted: generated check is a symlink"
  assert_present "$home/state/wait-1.check-trust" "accepted: arming must write the trust binding"

  fm_custom_check_registered "$home/state" wait-1 \
    || fail "accepted: the watcher's registration gate rejected the generated check"
  fm_custom_check_snapshot_prepare "$home/state" wait-1 \
    || fail "accepted: the watcher's snapshot gate rejected the generated check"
  fm_custom_check_snapshot_cleanup

  # Re-registering the untouched bytes through the public command must succeed.
  assert_contains "$(FM_HOME="$home" "$REGISTER" wait-1)" "registered: state/wait-1.check.sh" \
    "accepted: fm-check-register.sh must accept the generated check"
  pass "the generated check is accepted by fm-check-register.sh and the watcher's own gates"
}

test_tampered_check_is_refused() {
  local home
  home=$(make_home tampered)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "tampered: arming failed"
  fm_custom_check_registered "$home/state" wait-1 || fail "tampered: baseline registration failed"

  printf 'printf "always ready\\n"\n' >> "$home/state/wait-1.check.sh"

  if fm_custom_check_registered "$home/state" wait-1; then
    fail "tampered: an edited check still satisfied its recorded hash"
  fi
  if fm_custom_check_snapshot_prepare "$home/state" wait-1; then
    fm_custom_check_snapshot_cleanup
    fail "tampered: the watcher would have executed an edited check"
  fi
  fm_custom_check_snapshot_cleanup
  pass "an edited check no longer matches its binding, so the watcher refuses to execute it"
}

# End-to-end through the real watcher: the strongest available evidence that a
# generated check is executable under the production sweep rather than merely
# well-formed. bin/fm-watch.sh prints one actionable wake and exits, so a bounded
# run either produces the check wake or times out.
test_real_watcher_executes_the_armed_check_and_queues_the_wake() {
  local home rc out
  home=$(make_home watcher)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "watcher: arming failed"
  printf 'the finished artifact\n' > "$home/artifacts/report.md"
  # One sweep records the signature; the watcher's own sweep is then the second.
  sweep "$home" >/dev/null
  touch "$home/state/.last-watcher-beat"

  set +e
  perl -e 'my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err"
  rc=$?
  set -e

  expect_code 0 "$rc" "watcher: bounded watcher run did not exit on the artifact wake ($(head -3 "$home/watch.err"))"
  out=$(cat "$home/watch.out")
  assert_contains "$out" "check: " "watcher: the wake was not classified as a check wake"
  assert_contains "$out" "artifact ready:" "watcher: the check's line did not reach the wake reason"
  assert_grep "artifact ready:" "$home/state/.wake-queue" \
    "watcher: the artifact wake was not queued durably"
  pass "the real watcher executes the armed check and queues its line as a durable check wake"
}

test_finishes_well_inside_the_check_timeout() {
  local home start elapsed
  home=$(make_home timing)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "timing: arming failed"
  printf 'done\n' > "$home/artifacts/report.md"
  start=$(date +%s)
  sweep "$home" >/dev/null
  sweep "$home" >/dev/null
  elapsed=$(( $(date +%s) - start ))
  # FM_CHECK_TIMEOUT defaults to 30s per sweep; two sweeps must not approach it.
  [ "$elapsed" -lt 10 ] || fail "timing: two sweeps took ${elapsed}s, too close to FM_CHECK_TIMEOUT"
  pass "the generated check finishes well inside FM_CHECK_TIMEOUT"
}

test_refuses_input_that_would_arm_a_watch_that_can_never_match() {
  local home out rc
  home=$(make_home refusals)

  set +e
  out=$(arm "$home" wait-1 artifacts/report.md 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: a relative dependency path must be refused"
  assert_contains "$out" "must be absolute" "refusals: relative path error must say why"

  set +e
  out=$(arm "$home" wait-1 "$home/artifacts/report.md" --sentinel 'a[' 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: an uncompilable sentinel must be refused"
  assert_contains "$out" "not a valid extended regular expression" \
    "refusals: bad sentinel error must say why"

  set +e
  out=$(arm "$home" wait-1 "$home/artifacts/report.md" --sentinel 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: --sentinel with no value must be refused"

  # An empty sentinel must not quietly downgrade a per-section wake into a
  # whole-file stability wake, which fires on an unmarked partial report.
  set +e
  out=$(arm "$home" wait-1 "$home/artifacts/report.md" --sentinel '' 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: an empty sentinel must be refused"
  assert_contains "$out" "--sentinel requires a value" \
    "refusals: empty sentinel error must say why"

  set +e
  out=$(arm "$home" wait-1 "$home/artifacts/report.md" --sentinel= 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: an empty --sentinel= must be refused"

  set +e
  out=$(arm "$home" wait-1 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: a wait with no dependency path must be refused"

  set +e
  out=$(arm "$home" ../escape "$home/artifacts/report.md" 2>&1); rc=$?
  set -e
  expect_code 2 "$rc" "refusals: an unsafe task id must be refused"

  set +e
  out=$(arm "$home" no-such-task "$home/artifacts/report.md" 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "refusals: a task with no metadata must be refused"
  assert_contains "$out" "no task metadata" "refusals: missing-task error must say why"

  assert_absent "$home/state/wait-1.check.sh" "refusals: no refused call may arm a check"
  pass "a wait that could never match is refused at arming, where it can still be reported"
}

# A task has one state check, so arming a merge poll on a task that is still
# waiting on an artifact necessarily retires that wake. The poll always wins -
# it is never blocked - but the replacement must be visible in the output.
arm_pr_poll() {  # <home>
  FM_HOME="$1" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-pr-check.sh" \
    wait-1 https://github.com/example/repo/pull/1 2>/dev/null
}

test_pr_poll_reports_the_artifact_wake_it_replaces() {
  local home out rc
  home=$(make_home pr-replaces)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "replace: arming failed"

  set +e
  out=$(arm_pr_poll "$home"); rc=$?
  set -e
  expect_code 0 "$rc" "replace: a legitimate merge poll must never be blocked by an artifact wake"
  assert_contains "$out" "replaced: unfired artifact wake state/wait-1.check.sh" \
    "replace: the replaced artifact wake must be named in the output"
  assert_contains "$out" "armed: state/wait-1.check.sh" "replace: the merge poll must still arm"
  fm_pr_poll_artifacts_valid "$home/state" wait-1 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "replace: the merge poll did not actually take over the state check"
  pass "arming a merge poll over an unfired artifact wake proceeds and names what it replaced"
}

test_pr_poll_reports_nothing_when_no_artifact_wake_is_pending() {
  local home out

  # A task whose artifact wake already fired has nothing left to lose.
  home=$(make_home pr-fired)
  arm "$home" wait-1 "$home/artifacts/report.md" >/dev/null || fail "fired: arming failed"
  printf 'the finished artifact\n' > "$home/artifacts/report.md"
  sweep "$home" >/dev/null
  assert_contains "$(sweep "$home")" "artifact ready:" "fired: the wake must fire before this case"
  out=$(arm_pr_poll "$home") || fail "fired: arming the merge poll failed"
  assert_not_contains "$out" "replaced:" \
    "fired: a spent artifact wake must not be reported as a lost wake"
  assert_contains "$out" "armed: state/wait-1.check.sh" "fired: the merge poll must still arm"

  # A task that never had an artifact wake at all.
  home=$(make_home pr-none)
  out=$(arm_pr_poll "$home") || fail "none: arming the merge poll failed"
  assert_not_contains "$out" "replaced:" "none: a task with no artifact wake reported a replacement"
  pass "a merge poll reports a replacement only when an unfired artifact wake is actually retired"
}

test_never_clobbers_another_owner_s_state_check() {
  local home out rc before after
  home=$(make_home foreign)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/wait-1.check.sh"
  chmod 0700 "$home/state/wait-1.check.sh"
  before=$(shasum -a 256 "$home/state/wait-1.check.sh" | awk '{print $1}')

  set +e
  out=$(arm "$home" wait-1 "$home/artifacts/report.md" 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "foreign: arming over another owner's check must be refused"
  assert_contains "$out" "already armed" "foreign: refusal must name the conflict"
  after=$(shasum -a 256 "$home/state/wait-1.check.sh" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "foreign: the pre-existing state check was modified"
  pass "an artifact wake never clobbers a PR poll or any other armed state check"
}

test_help_includes_entire_header
test_silent_until_present_stable_then_fires_exactly_once
test_symlinked_dependency_is_judged_by_its_target
test_empty_file_is_not_ready
test_every_path_must_be_ready
test_sentinel_fires_on_the_marker_and_not_on_stability
test_sentinel_form_with_equals_and_rearming
test_generated_check_is_accepted_by_the_registration_contract
test_tampered_check_is_refused
test_real_watcher_executes_the_armed_check_and_queues_the_wake
test_finishes_well_inside_the_check_timeout
test_refuses_input_that_would_arm_a_watch_that_can_never_match
test_never_clobbers_another_owner_s_state_check
test_pr_poll_reports_the_artifact_wake_it_replaces
test_pr_poll_reports_nothing_when_no_artifact_wake_is_pending
