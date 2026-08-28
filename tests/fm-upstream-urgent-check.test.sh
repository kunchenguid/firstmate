#!/usr/bin/env bash
# Behavior tests for the upstream urgent tripwire.
#
# Each case uses a fixture repository and a local bare upstream remote, so the
# check exercises its real fetch and commit-range behavior without contacting a
# network or depending on the host repository's history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The trust binding is a byte contract between arm and the watcher, so the tests
# ask its owner whether a shim is registered rather than re-running the
# registrar, which would rewrite the binding from whatever bytes it finds.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

CHECK="$ROOT/bin/fm-upstream-urgent-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-urgent-check)
CANONICAL_UPSTREAM_URL='git@github.com:kunchenguid/firstmate.git'

make_fixture_repo() {
  local name=$1 initial_subject=${2:-initial} repo remote base real_git
  repo="$TMP_ROOT/$name/repo"
  remote="$TMP_ROOT/$name/upstream.git"
  fm_git_init_commit "$repo"
  git -C "$repo" commit --amend -qm "$initial_subject"
  git -C "$repo" branch -M main
  base=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$repo/docs"
  printf '%s\n' \
    '# Upstream sync' \
    '' \
    '| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |' \
    '| --- | --- | --- | --- | --- |' \
    "| 2026-08-27 | \`$base\` (\`upstream/main\`) | \`$base\` | weekly | fixture |" \
    > "$repo/docs/upstream-sync.md"
  git -C "$repo" add docs/upstream-sync.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'docs: record fixture catch-up'
  git clone --quiet --bare "$repo" "$remote"
  git -C "$repo" remote add upstream "$CANONICAL_UPSTREAM_URL"
  real_git=$(command -v git)
  mkdir -p "$TMP_ROOT/$name/fakebin"
  cat > "$TMP_ROOT/$name/fakebin/git" <<SH
#!/usr/bin/env bash
set -u
args=( "\$@" )
case " \$* " in
  *' remote get-url upstream '*)
    printf '%s\n' '$CANONICAL_UPSTREAM_URL'
    exit 0
    ;;
  *' fetch '*)
    for i in "\${!args[@]}"; do
      [ "\${args[\$i]}" = upstream ] && args[\$i]="file://$remote"
    done
    exec '$real_git' "\${args[@]}"
    ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$TMP_ROOT/$name/fakebin/git"
  printf '%s\n' "$repo"
}

publish_upstream_commit() {
  local repo=$1 name=$2 subject=$3 body=$4 remote work commit
  remote="${repo%/repo}/upstream.git"
  work="$TMP_ROOT/$name/work"
  git clone --quiet "$remote" "$work"
  git -C "$work" config user.name 'Firstmate Tests'
  git -C "$work" config user.email 'tests@example.invalid'
  printf '%s\n%s\n' "$subject" "$body" > "$work/change.txt"
  git -C "$work" add change.txt
  git -C "$work" commit -qm "$subject" -m "$body"
  commit=$(git -C "$work" rev-parse HEAD)
  git -C "$work" push --quiet origin main
  printf '%s\n' "$commit"
}

fixture_fakebin() {
  printf '%s\n' "${1%/repo}/fakebin"
}

run_check() {
  local repo=$1 out=$2 status=0
  env PATH="$(fixture_fakebin "$repo"):$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "upstream urgent check exit"
}

test_check_uses_one_fetch_and_finishes_quickly() {
  local repo out fakebin real_git fetches elapsed
  repo=$(make_fixture_repo fetch-budget)
  publish_upstream_commit "$repo" fetch-budget 'docs: refresh examples' 'Routine wording cleanup.' >/dev/null
  fakebin="$TMP_ROOT/fetch-budget/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
args=( "\$@" )
case " \$* " in
  *' remote get-url upstream '*) printf '%s\n' '$CANONICAL_UPSTREAM_URL'; exit 0 ;;
  *' fetch '*)
    printf '%s\n' fetch >> '$TMP_ROOT/fetch-budget/fetches.log'
    for i in "\${!args[@]}"; do
      [ "\${args[\$i]}" = upstream ] && args[\$i]="file://$TMP_ROOT/fetch-budget/upstream.git"
    done
    exec '$real_git' "\${args[@]}"
    ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/fetch-budget/report.txt"
  SECONDS=0
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>&1
  elapsed=$SECONDS
  fetches=$(wc -l < "$TMP_ROOT/fetch-budget/fetches.log" | tr -d '[:space:]')
  [ "$fetches" = 1 ] || fail "tripwire used $fetches fetches instead of one"
  [ "$elapsed" -lt 10 ] || fail "tripwire took ${elapsed}s, expected under 10s"
  pass 'tripwire uses one fetch and stays under the ten-second budget'
}

test_slow_fetch_is_bounded_before_ten_seconds() {
  local repo out fakebin real_git elapsed status
  repo=$(make_fixture_repo slow-fetch)
  fakebin="$TMP_ROOT/slow-fetch/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' remote get-url upstream '*) printf '%s\n' '$CANONICAL_UPSTREAM_URL'; exit 0 ;;
  *' fetch '*) sleep 11; exit 1 ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/slow-fetch/report.txt"
  status=0
  SECONDS=0
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  elapsed=$SECONDS
  [ "$status" -ne 0 ] || fail 'a failed fetch was reported as a clean check'
  [ "$elapsed" -lt 10 ] || fail "slow fetch took ${elapsed}s, expected a sub-ten-second bound"
  pass 'slow fetch is bounded before ten seconds'
}

test_slow_local_scan_is_bounded_before_ten_seconds() {
  local repo out err fakebin real_git elapsed status=0
  repo=$(make_fixture_repo slow-log)
  publish_upstream_commit "$repo" slow-log 'docs: refresh examples' 'Routine wording cleanup.' >/dev/null
  fakebin="$TMP_ROOT/slow-log/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
args=( "\$@" )
case " \$* " in
  *' remote get-url upstream '*) printf '%s\n' '$CANONICAL_UPSTREAM_URL'; exit 0 ;;
  *' fetch '*)
    for i in "\${!args[@]}"; do
      [ "\${args[\$i]}" = upstream ] && args[\$i]="file://$TMP_ROOT/slow-log/upstream.git"
    done
    exec '$real_git' "\${args[@]}"
    ;;
  *' log '*) sleep 11; exit 1 ;;
esac
exec '$real_git' "\${args[@]}"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/slow-log/report.txt"
  err="$TMP_ROOT/slow-log/error.txt"
  SECONDS=0
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>"$err" || status=$?
  elapsed=$SECONDS
  [ "$status" -ne 0 ] || fail 'a stalled local scan was reported as a clean check'
  [ "$elapsed" -lt 10 ] || fail "slow local scan took ${elapsed}s, expected a sub-ten-second bound"
  [ ! -s "$out" ] || fail "a timed-out local scan woke firstmate: $(cat "$out")"
  pass 'slow local scan is bounded before ten seconds'
}

test_check_fits_inside_configured_watcher_timeout() {
  local repo out err fakebin real_git elapsed status=0
  repo=$(make_fixture_repo configured-timeout)
  publish_upstream_commit "$repo" configured-timeout 'docs: refresh examples' 'Routine wording cleanup.' >/dev/null
  fakebin="$TMP_ROOT/configured-timeout/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
args=( "\$@" )
case " \$* " in
  *' remote get-url upstream '*) printf '%s\n' '$CANONICAL_UPSTREAM_URL'; exit 0 ;;
  *' fetch '*)
    for i in "\${!args[@]}"; do
      [ "\${args[\$i]}" = upstream ] && args[\$i]="file://$TMP_ROOT/configured-timeout/upstream.git"
    done
    exec '$real_git' "\${args[@]}"
    ;;
  *' log '*) sleep 6; exit 1 ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/configured-timeout/report.txt"
  err="$TMP_ROOT/configured-timeout/error.txt"
  SECONDS=0
  env PATH="$fakebin:$PATH" FM_CHECK_TIMEOUT=5 FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>"$err" || status=$?
  elapsed=$SECONDS
  [ "$status" -ne 0 ] || fail 'a stalled scan was reported as a clean check'
  [ "$elapsed" -lt 5 ] || fail "configured watcher timeout was exceeded: ${elapsed}s"
  [ ! -s "$out" ] || fail "a timed-out scan woke firstmate: $(cat "$out")"
  pass 'the check fits inside a configured watcher timeout'
}

test_timeout_parser_accepts_decimal_values_without_overflow() {
  local repo out status value
  repo=$(make_fixture_repo timeout-parser)
  out="$TMP_ROOT/timeout-parser/out.txt"
  for value in 08 09 00000000008 999999999999999999999999; do
    status=0
    env PATH="$(fixture_fakebin "$repo"):$PATH" FM_CHECK_TIMEOUT="$value" \
      FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>&1 || status=$?
    [ "$status" -eq 0 ] || fail "FM_CHECK_TIMEOUT=$value was rejected: $(cat "$out")"
    [ ! -s "$out" ] || fail "FM_CHECK_TIMEOUT=$value produced output: $(cat "$out")"
  done
  pass 'timeout parsing accepts decimal values without overflow'
}

test_noncanonical_upstream_remote_is_rejected() {
  local repo out status=0
  repo=$(make_fixture_repo noncanonical-remote)
  git -C "$repo" remote set-url upstream "file://$TMP_ROOT/noncanonical-remote/upstream.git"
  out="$TMP_ROOT/noncanonical-remote/report.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a noncanonical upstream remote was accepted'
  assert_contains "$(cat "$out")" 'upstream remote does not point at kunchenguid/firstmate' \
    'the rejected remote was not identified'
  pass 'the tripwire rejects a noncanonical upstream remote'
}

test_fatal_merge_base_failure_is_retryable() {
  local repo out err fakebin real_git status=0
  repo=$(make_fixture_repo merge-base-fatal)
  fakebin="$TMP_ROOT/merge-base-fatal/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
args=( "\$@" )
case " \$* " in
  *' remote get-url upstream '*) printf '%s\n' '$CANONICAL_UPSTREAM_URL'; exit 0 ;;
  *' fetch '*)
    for i in "\${!args[@]}"; do
      [ "\${args[\$i]}" = upstream ] && args[\$i]="file://$TMP_ROOT/merge-base-fatal/upstream.git"
    done
    exec '$real_git' "\${args[@]}"
    ;;
  *' merge-base --is-ancestor '*) printf '%s\n' 'object database unavailable' >&2; exit 128 ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/merge-base-fatal/out.txt"
  err="$TMP_ROOT/merge-base-fatal/err.txt"
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'a fatal merge-base failure exited zero'
  [ ! -s "$out" ] || fail "a fatal merge-base failure woke firstmate: $(cat "$out")"
  assert_contains "$(cat "$err")" 'could not verify recorded base ancestry' \
    'a fatal merge-base failure was not treated as retryable'
  [ ! -e "$repo/state/.upstream-urgent" ] || fail 'a retryable merge-base failure wrote a report record'
  pass 'fatal merge-base failures remain retryable and silent'
}

test_arm_registers_and_disarm_removes_the_check() {
  local repo shim out
  repo=$(make_fixture_repo arm)
  out="$TMP_ROOT/arm/arm.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >"$out"
  assert_contains "$(cat "$out")" 'armed: state/upstream-urgent.check.sh' \
    'arm did not report the registered check'
  shim="$repo/state/upstream-urgent.check.sh"
  [ -x "$shim" ] || fail 'arm did not create an executable check shim'
  fm_custom_check_registered "$repo/state" upstream-urgent \
    || fail 'arm left a check whose trust binding does not cover its bytes'
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >"$out"
  [ ! -e "$shim" ] || fail 'disarm left the check shim in place'
  [ ! -e "$repo/state/upstream-urgent.check-trust" ] \
    || fail 'disarm left the check trust binding in place'
  pass 'arm registers and disarm removes the tripwire check'
}

test_arm_rejects_a_symlinked_state_parent() {
  local repo outside target_state out status=0
  repo=$(make_fixture_repo arm-symlink-parent)
  outside="$TMP_ROOT/arm-symlink-parent/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$repo/redirect"
  target_state="$outside/state"
  out="$TMP_ROOT/arm-symlink-parent/out.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    FM_STATE_OVERRIDE="$repo/redirect/state" "$CHECK" arm >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'arm followed a symlinked state parent'
  [ ! -e "$target_state" ] || fail 'arm created state through a symlinked parent'
  pass 'arm rejects a symlinked state parent before creation'
}

test_arm_rejects_a_trailing_slash_state_symlink() {
  local repo outside out status=0
  repo=$(make_fixture_repo arm-trailing-state)
  outside="$TMP_ROOT/arm-trailing-state/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$repo/redirect"
  out="$TMP_ROOT/arm-trailing-state/out.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    FM_STATE_OVERRIDE="$repo/redirect/" "$CHECK" arm >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'arm followed a trailing-slash state symlink'
  [ ! -e "$outside/upstream-urgent.check.sh" ] \
    || fail 'arm created the check through a trailing-slash state symlink'
  pass 'arm rejects a trailing-slash state symlink before creation'
}

test_disarm_reports_cleanup_failure() {
  local repo out status=0
  repo=$(make_fixture_repo disarm-failure)
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >/dev/null
  rm -f "$repo/state/upstream-urgent.check.sh"
  mkdir "$repo/state/upstream-urgent.check.sh"
  out="$TMP_ROOT/disarm-failure/out.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'disarm reported success after rm failed'
  [ -d "$repo/state/upstream-urgent.check.sh" ] \
    || fail 'disarm unexpectedly removed the failed cleanup target'
  [ ! -e "$repo/state/upstream-urgent.check-trust" ] \
    || fail 'disarm stopped before removing the trust binding'
  assert_not_contains "$(cat "$out")" 'disarmed: state/upstream-urgent.check.sh' \
    'disarm claimed success after incomplete cleanup'
  pass 'disarm reports incomplete cleanup as a failure'
}

test_disarm_rejects_missing_state() {
  local repo out status=0
  repo=$(make_fixture_repo disarm-missing)
  out="$TMP_ROOT/disarm-missing/out.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'disarm reported success without a state directory'
  assert_not_contains "$(cat "$out")" 'disarmed: state/upstream-urgent.check.sh' \
    'disarm claimed success without a state directory'
  pass 'disarm rejects a missing state directory'
}

test_disarm_rejects_symlinked_state() {
  local repo outside out status=0
  repo=$(make_fixture_repo disarm-symlink)
  outside="$TMP_ROOT/disarm-symlink/outside"
  mkdir -p "$outside"
  printf 'shim sentinel\n' > "$outside/upstream-urgent.check.sh"
  printf 'trust sentinel\n' > "$outside/upstream-urgent.check-trust"
  printf 'record sentinel\n' > "$outside/.upstream-urgent"
  ln -s "$outside" "$repo/state"
  out="$TMP_ROOT/disarm-symlink/out.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >"$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'disarm reported success through a symlinked state directory'
  [ "$(cat "$outside/upstream-urgent.check.sh")" = 'shim sentinel' ] \
    || fail 'disarm removed a file through the state symlink'
  [ "$(cat "$outside/upstream-urgent.check-trust")" = 'trust sentinel' ] \
    || fail 'disarm removed trust through the state symlink'
  [ "$(cat "$outside/.upstream-urgent")" = 'record sentinel' ] \
    || fail 'disarm removed the record through the state symlink'
  assert_not_contains "$(cat "$out")" 'disarmed: state/upstream-urgent.check.sh' \
    'disarm claimed success through a state symlink'
  pass 'disarm rejects a symlinked state directory'
}

# A pending urgent commit stays pending for days, until a sync advances the
# base. A report of the other kind between two successful polls must not make
# the same unchanged commit set news again.
test_an_interrupting_report_does_not_reannounce_an_unchanged_hit() {
  local repo out err status=0
  repo=$(make_fixture_repo failure-between-hits)
  publish_upstream_commit "$repo" failure-between-hits 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/failure-between-hits/out.txt"
  run_check "$repo" "$out"
  assert_contains "$(cat "$out")" 'urgent upstream commits:' 'the first sweep did not report the hit'

  # An unusable-tripwire report must stay off stdout, so it cannot wake
  # firstmate or evict the hit's suppression state.
  git -C "$repo" remote remove upstream
  err="$TMP_ROOT/failure-between-hits/err.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'a check with no upstream remote exited zero'
  [ ! -s "$out" ] || fail "the interruption woke firstmate: $(cat "$out")"
  assert_contains "$(cat "$err")" 'upstream urgent check failed:' 'the interruption produced no stderr diagnostic'

  git -C "$repo" remote add upstream "$CANONICAL_UPSTREAM_URL"
  run_check "$repo" "$out"
  [ ! -s "$out" ] \
    || fail "a transient failure re-announced an unchanged hit: $(cat "$out")"
  pass 'an interrupting report never re-announces an unchanged commit set'
}

# Only a condition a human had to clear can reach this path, so re-reporting it
# after it genuinely came back is one wake per reintroduction, not per poll.
test_a_reintroduced_unusable_tripwire_is_news_again() {
  local repo out err status=0
  repo=$(make_fixture_repo failure-after-clean)
  out="$TMP_ROOT/failure-after-clean/out.txt"
  err="$TMP_ROOT/failure-after-clean/err.txt"
  git -C "$repo" remote remove upstream
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'a check with no upstream remote exited zero'
  [ ! -s "$out" ] || fail 'the first unusable-tripwire report woke firstmate'
  [ -s "$err" ] || fail 'the first unusable-tripwire diagnostic was silent'

  git -C "$repo" remote add upstream "$CANONICAL_UPSTREAM_URL"
  run_check "$repo" "$out"
  [ ! -s "$out" ] || fail "a clean sweep reported something: $(cat "$out")"

  git -C "$repo" remote remove upstream
  status=0
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'the reintroduced condition exited zero'
  [ ! -s "$out" ] || fail "the reintroduced condition woke firstmate: $(cat "$out")"
  assert_contains "$(cat "$err")" 'upstream urgent check failed:' \
    'a condition reintroduced after a repair was suppressed'
  pass 'a reintroduced unusable tripwire is news again'
}

test_matching_upstream_commit_is_reported() {
  local repo out report commit
  repo=$(make_fixture_repo hit)
  commit=$(publish_upstream_commit "$repo" hit 'security: rotate the signing key' 'Routine key rotation after the security review.')
  out="$TMP_ROOT/hit/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'urgent upstream commits:' 'matching upstream commit did not wake the check'
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" 'report did not name the matching commit'
  assert_contains "$report" 'security: rotate the signing key' 'report did not include the matching subject'
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] \
    || fail "urgent report must be exactly one line: $(cat "$out")"
  pass 'matching upstream subject is reported in one line'
}

test_matching_upstream_body_is_reported() {
  local repo out report commit
  repo=$(make_fixture_repo body-hit)
  commit=$(publish_upstream_commit "$repo" body-hit 'chore: refresh dependency notes' 'The credential rotation procedure is documented here.')
  out="$TMP_ROOT/body-hit/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" 'report did not name a body-only match'
  assert_contains "$report" 'chore: refresh dependency notes' 'report did not include the body-only match subject'
  pass 'matching upstream body is reported'
}

test_record_separator_in_body_keeps_commit_identity() {
  local repo out report commit
  repo=$(make_fixture_repo separator-body)
  commit=$(publish_upstream_commit "$repo" separator-body 'chore: refresh dependency notes' $'Routine notes.\036The credential rotation procedure is documented here.')
  out="$TMP_ROOT/separator-body/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" \
    'a record separator in the body changed the reported commit identity'
  assert_contains "$report" 'chore: refresh dependency notes' \
    'the commit with a record separator in its body was not reported'
  pass 'commit bodies do not corrupt urgent report framing'
}

test_control_bytes_are_removed_from_subjects() {
  local repo out report clean
  repo=$(make_fixture_repo control-bytes)
  publish_upstream_commit "$repo" control-bytes $'security: rotate\033 the\007 signing\010 key\177' 'Body.' >/dev/null
  out="$TMP_ROOT/control-bytes/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'security: rotate' 'the control-byte hit was not reported'
  clean=$(printf '%s' "$report" | LC_ALL=C tr -d '[:cntrl:]')
  [ "$clean" = "$report" ] || fail 'the report contains a control byte'
  pass 'urgent subjects are emitted without control bytes'
}

test_utf8_subject_truncation_preserves_character_boundaries() {
  local repo out report subject
  repo=$(make_fixture_repo utf8-cap)
  subject="security:$(printf '界%.0s' {1..1100})"
  publish_upstream_commit "$repo" utf8-cap "$subject" 'Body.' >/dev/null
  out="$TMP_ROOT/utf8-cap/report.txt"
  env LC_ALL=en_US.UTF-8 PATH="$(fixture_fakebin "$repo"):$PATH" \
    FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>&1
  report=$(cat "$out")
  assert_contains "$report" '[truncated]' 'the long UTF-8 urgent subject was not capped'
  (set -o pipefail; LC_ALL=C iconv -f UTF-8 -t UTF-8 "$out" | LC_ALL=C wc -c >/dev/null) \
    || fail 'the capped urgent report contains an incomplete UTF-8 character'
  pass 'UTF-8 subject truncation preserves character boundaries'
}

test_nonmatching_upstream_commit_is_silent() {
  local repo out
  repo=$(make_fixture_repo no-hit)
  publish_upstream_commit "$repo" no-hit 'docs: clarify the sync example' 'Routine wording cleanup.' >/dev/null
  out="$TMP_ROOT/no-hit/report.txt"
  run_check "$repo" "$out"
  [ ! -s "$out" ] || fail "nonmatching upstream commit produced a wake: $(cat "$out")"
  pass 'nonmatching upstream subject and body are silent'
}

test_unusable_inspection_does_not_wake_watcher() {
  local repo out err status=0
  repo=$(make_fixture_repo watcher-unusable)
  git -C "$repo" remote remove upstream
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >/dev/null \
    || fail 'could not arm the watcher tripwire for the unusable inspection'
  out="$TMP_ROOT/watcher-unusable/checkpoint.out"
  err="$TMP_ROOT/watcher-unusable/checkpoint.err"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" 'an unusable tripwire must stay quiet to the watcher'
  assert_contains "$(cat "$out")" 'checkpoint: no actionable wake' \
    'an unusable tripwire produced an actionable checkpoint output'
  [ ! -s "$repo/state/.wake-queue" ] \
    || fail "an unusable tripwire queued a firstmate wake: $(cat "$repo/state/.wake-queue")"
  pass 'an unusable tripwire does not wake firstmate'
}

test_recorded_base_is_excluded_from_the_range() {
  local repo out
  repo=$(make_fixture_repo base-excluded 'security: already handled')
  publish_upstream_commit "$repo" base-excluded 'docs: refresh examples' 'Routine wording cleanup.' >/dev/null
  out="$TMP_ROOT/base-excluded/report.txt"
  run_check "$repo" "$out"
  [ ! -s "$out" ] || fail "the recorded base was re-reported: $(cat "$out")"
  pass 'the recorded sync base is excluded from the urgent range'
}

# The tracked catch-up log records the adopted upstream base first and may name
# a later origin/main landing hash in the same cell. Extracting the last hash
# instead of the first resolves a commit that is by construction not on
# upstream/main, which fails the ancestor guard and silently disables the
# tripwire, so the real row shape is exercised directly.
test_base_is_read_from_a_row_that_also_names_a_landing_hash() {
  local repo out report commit base landed
  repo=$(make_fixture_repo landing-hash)
  base=$(git -C "$repo" rev-parse HEAD~1)
  landed=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' \
    '# Upstream sync' \
    '' \
    '| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |' \
    '| --- | --- | --- | --- | --- |' \
    "| 2026-08-27 | \`$base\` (\`upstream/main\`), landed on \`origin/main\` as \`$landed\` (\`#78\`) | \`$landed\` | full | fixture |" \
    > "$repo/docs/upstream-sync.md"
  commit=$(publish_upstream_commit "$repo" landing-hash 'fix: patch a security hole' 'Body.')
  out="$TMP_ROOT/landing-hash/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'urgent upstream commits:' \
    'a catch-up row naming a landing hash disabled the tripwire'
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" \
    'report did not name the commit found from the adopted base'
  pass 'the adopted base is read past a later origin/main landing hash'
}

test_unchanged_match_set_is_reported_once() {
  local repo first second third fourth
  repo=$(make_fixture_repo report-once)
  publish_upstream_commit "$repo" report-once 'security: rotate the signing key' 'Body.' >/dev/null
  first="$TMP_ROOT/report-once/first.txt"
  second="$TMP_ROOT/report-once/second.txt"
  run_check "$repo" "$first"
  [ -s "$first" ] || fail 'the first sweep did not report the matching commit'
  run_check "$repo" "$second"
  [ ! -s "$second" ] \
    || fail "an unchanged match set was reported again: $(cat "$second")"

  # A new matching commit is still news, so suppression is per match set rather
  # than a latch that silences the tripwire for good.
  publish_upstream_commit "$repo" report-once-more 'fix: revert the bad migration' 'Body.' >/dev/null
  third="$TMP_ROOT/report-once/third.txt"
  run_check "$repo" "$third"
  [ -s "$third" ] || fail 'a newly matching upstream commit was suppressed'
  fourth="$TMP_ROOT/report-once/fourth.txt"
  run_check "$repo" "$fourth"
  [ ! -s "$fourth" ] || fail "the grown match set was reported twice: $(cat "$fourth")"
  pass 'one match set wakes once and a new match is still news'
}

test_disarm_removes_the_report_record() {
  local repo out
  repo=$(make_fixture_repo record-disarm)
  publish_upstream_commit "$repo" record-disarm 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/record-disarm/report.txt"
  run_check "$repo" "$out"
  [ -f "$repo/state/.upstream-urgent" ] || fail 'the check wrote no report record'
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >/dev/null
  [ ! -e "$repo/state/.upstream-urgent" ] || fail 'disarm left the report record behind'
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'a disarmed and re-run check did not report again'
  pass 'disarm drops the report record so the next run reports again'
}

test_symlinked_record_does_not_suppress_a_hit() {
  local repo out outside
  repo=$(make_fixture_repo symlinked-record)
  publish_upstream_commit "$repo" symlinked-record 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/symlinked-record/report.txt"
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'the initial hit was not reported'
  outside="$TMP_ROOT/symlinked-record/outside"
  mkdir -p "$outside"
  mv "$repo/state/.upstream-urgent" "$outside/record"
  ln -s "$outside/record" "$repo/state/.upstream-urgent"
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'a symlinked record suppressed the urgent hit'
  pass 'a symlinked record cannot suppress an urgent hit'
}

test_hardlinked_record_does_not_suppress_a_hit() {
  local repo out outside
  repo=$(make_fixture_repo hardlinked-record)
  publish_upstream_commit "$repo" hardlinked-record 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/hardlinked-record/report.txt"
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'the initial hit was not reported'
  outside="$TMP_ROOT/hardlinked-record/outside"
  mkdir -p "$outside"
  mv "$repo/state/.upstream-urgent" "$outside/record"
  ln "$outside/record" "$repo/state/.upstream-urgent"
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'a hardlinked record suppressed the urgent hit'
  pass 'a hardlinked record cannot suppress an urgent hit'
}

test_nonprivate_record_does_not_suppress_a_hit() {
  local repo out record
  repo=$(make_fixture_repo nonprivate-record)
  publish_upstream_commit "$repo" nonprivate-record 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/nonprivate-record/report.txt"
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'the initial hit was not reported'
  record="$repo/state/.upstream-urgent"
  chmod 0644 "$record"
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'a non-private record suppressed the urgent hit'
  pass 'a non-private record cannot suppress an urgent hit'
}

test_malformed_record_does_not_suppress_a_hit() {
  local repo out record reported failed malformed
  repo=$(make_fixture_repo malformed-record)
  publish_upstream_commit "$repo" malformed-record 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/malformed-record/report.txt"
  run_check "$repo" "$out"
  record="$repo/state/.upstream-urgent"
  reported=$(sed -n '2s/^reported=//p' "$record")
  failed=$(sed -n '3s/^failed=//p' "$record")
  for malformed in missing duplicate unknown truncated; do
    case "$malformed" in
      missing)
        printf '%s\n%s\n' 'fm-upstream-urgent-v2' "reported=$reported" > "$record"
        ;;
      duplicate)
        printf '%s\n%s\n%s\n%s\n' 'fm-upstream-urgent-v2' "reported=$reported" \
          "failed=$failed" "failed=$failed" > "$record"
        ;;
      unknown)
        printf '%s\n%s\n%s\n%s\n' 'fm-upstream-urgent-v2' "reported=$reported" \
          'unknown=field' "failed=$failed" > "$record"
        ;;
      truncated)
        printf '%s\n%s\n%s' 'fm-upstream-urgent-v2' "reported=$reported" "failed=$failed" > "$record"
        ;;
    esac
    chmod 0600 "$record"
    run_check "$repo" "$out"
    [ -s "$out" ] || fail "a $malformed record suppressed the urgent hit"
  done
  pass 'malformed report records cannot suppress urgent hits'
}

test_record_directory_is_not_used_as_record_target() {
  local repo out record
  repo=$(make_fixture_repo record-directory)
  publish_upstream_commit "$repo" record-directory 'security: rotate the signing key' 'Body.' >/dev/null
  record="$repo/state/.upstream-urgent"
  mkdir -p "$record"
  out="$TMP_ROOT/record-directory/report.txt"
  run_check "$repo" "$out"
  [ -z "$(find "$record" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail 'record writing placed a temporary file inside the record directory'
  pass 'record writing rejects a directory record destination'
}

test_dangling_state_symlink_is_not_created() {
  local repo target out
  repo=$(make_fixture_repo dangling-state)
  publish_upstream_commit "$repo" dangling-state 'security: rotate the signing key' 'Body.' >/dev/null
  target="$TMP_ROOT/dangling-state/missing-target"
  ln -s "$target" "$repo/state"
  out="$TMP_ROOT/dangling-state/report.txt"
  run_check "$repo" "$out"
  [ -L "$repo/state" ] || fail 'the dangling state symlink was replaced'
  [ ! -e "$target" ] || fail 'record writing created the dangling state target'
  pass 'record writing rejects a dangling state symlink before creation'
}

# The watcher redirects a check's stderr to /dev/null and ignores its exit
# status (bin/fm-watch.sh), so an unusable inspection must stay off stdout: only
# a matching commit may wake firstmate. A hand run still receives one stderr
# diagnostic.
test_inspection_failure_is_reported_on_stderr_once() {
  local repo stray out err second_out second_err status=0
  repo=$(make_fixture_repo unreachable-base)
  # A base commit that exists in this clone but is not on upstream/main is the
  # shape a catch-up row takes when it names an origin/main snapshot squash.
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'chore: snapshot upstream main for the fixture'
  stray=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' \
    '# Upstream sync' \
    '' \
    '| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |' \
    '| --- | --- | --- | --- | --- |' \
    "| 2026-08-29 | \`$stray\` (\`#65\`, \`chore: snapshot upstream main\`) | \`$stray\` | full | fixture |" \
    > "$repo/docs/upstream-sync.md"
  out="$TMP_ROOT/unreachable-base/out.txt"
  err="$TMP_ROOT/unreachable-base/err.txt"
  env PATH="$(fixture_fakebin "$repo"):$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'a failed inspection exited zero'
  [ ! -s "$out" ] || fail "a failed inspection woke firstmate: $(cat "$out")"
  assert_contains "$(cat "$err")" 'upstream urgent check failed:' \
    'a failed inspection produced no stderr diagnostic'
  assert_contains "$(cat "$err")" 'is not an ancestor of upstream/main' \
    'the stderr failure line did not name the condition'
  [ "$(wc -l < "$err" | tr -d '[:space:]')" = 1 ] \
    || fail "the failure report must be exactly one line: $(cat "$err")"

  second_out="$TMP_ROOT/unreachable-base/out2.txt"
  second_err="$TMP_ROOT/unreachable-base/err2.txt"
  status=0
  env PATH="$(fixture_fakebin "$repo"):$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$second_out" 2>"$second_err" || status=$?
  [ "$status" -ne 0 ] || fail 'the second failed inspection exited zero'
  [ ! -s "$second_out" ] \
    || fail "an unchanged failure was reported again: $(cat "$second_out")"
  [ ! -s "$second_err" ] \
    || fail "an unchanged failure was reported again: $(cat "$second_err")"
  pass 'an inspection failure stays off stdout and diagnoses once on stderr'
}

# A fetch failure is retryable, so it must cost a non-zero exit and a stderr
# line and nothing else. The watcher turns any stdout line into a wake, and a
# flapping link would otherwise wake firstmate once per poll, indefinitely.
test_a_retryable_failure_never_reaches_stdout() {
  local repo out err fakebin real_git status=0 i
  repo=$(make_fixture_repo retryable-silent)
  fakebin="$TMP_ROOT/retryable-silent/failbin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' remote get-url upstream '*) printf '%s\n' '$CANONICAL_UPSTREAM_URL'; exit 0 ;;
  *' fetch '*) exit 1 ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/retryable-silent/out.txt"
  err="$TMP_ROOT/retryable-silent/err.txt"
  for i in 1 2 3; do
    status=0
    env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
      "$CHECK" check >"$out" 2>"$err" || status=$?
    [ "$status" -ne 0 ] || fail "sweep $i with a forced fetch failure exited zero"
    [ ! -s "$out" ] \
      || fail "a retryable failure woke firstmate on sweep $i: $(cat "$out")"
  done
  assert_contains "$(cat "$err")" 'fetch failed' \
    'a retryable failure left no stderr trace for a hand run'

  # Staying silent must not cost the hit that follows once the link is back.
  publish_upstream_commit "$repo" retryable-silent 'security: rotate the signing key' 'Body.' >/dev/null
  run_check "$repo" "$out"
  assert_contains "$(cat "$out")" 'urgent upstream commits:' \
    'a hit after a retryable failure was suppressed'
  pass 'a retryable failure stays off stdout and never costs a later hit'
}

# An unregistered shim is not inert: bin/fm-watch.sh rejects it on every sweep
# and wakes firstmate about unauthenticated state checks until someone deletes
# it by hand, so a home that could not be armed has to come back to the state
# it was in.
test_a_failed_registration_leaves_no_unregistered_shim() {
  local repo target status=0
  repo=$(make_fixture_repo arm-register-fail)
  mkdir -p "$repo/state"
  target="$TMP_ROOT/arm-register-fail/not-the-trust.txt"
  printf 'a file the trust binding must not touch\n' > "$target"
  ln -s "$target" "$repo/state/upstream-urgent.check-trust"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" 'arm with an unusable trust path exit'
  [ ! -e "$repo/state/upstream-urgent.check.sh" ] \
    || fail 'a failed registration left an unregistered check shim behind'
  [ "$(cat "$target")" = 'a file the trust binding must not touch' ] \
    || fail 'arm wrote through the trust symlink'

  printf '#!/usr/bin/env bash\n# a shim armed earlier\nexit 0\n' \
    > "$repo/state/upstream-urgent.check.sh"
  chmod 0700 "$repo/state/upstream-urgent.check.sh"
  status=0
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" 'arm over an existing shim with an unusable trust path exit'
  [ ! -e "$repo/state/upstream-urgent.check.sh" ] \
    || fail 'a failed arm left a shim behind that no trust binding covers'
  pass 'a failed registration never leaves a shim without a matching trust binding'
}

# A shim embeds the path it execs, so arming through a second directory of
# symlinks produces genuinely different bytes. Without that the re-armed shim
# would be byte-identical to the first and the restore assertion could not fail.
mirror_bin() {
  local dir=$1 f
  mkdir -p "$dir"
  for f in "$ROOT"/bin/*; do
    ln -s "$f" "$dir/$(basename "$f")"
  done
}

test_a_failed_rearm_restores_the_armed_shim() {
  local repo first_bin second_bin before status=0
  repo=$(make_fixture_repo arm-rearm-restore)
  first_bin="$TMP_ROOT/arm-rearm-restore/bin-one"
  second_bin="$TMP_ROOT/arm-rearm-restore/bin-two"
  mirror_bin "$first_bin"
  mirror_bin "$second_bin"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$first_bin/fm-upstream-urgent-check.sh" arm \
    >/dev/null || fail 'the first arm failed'
  before=$(cat "$repo/state/upstream-urgent.check.sh")

  # The register runs as a separate program, so a failure that leaves the
  # existing binding intact is staged by standing in for that program alone.
  rm -f "$second_bin/fm-check-register.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$second_bin/fm-check-register.sh"
  chmod 0755 "$second_bin/fm-check-register.sh"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$second_bin/fm-upstream-urgent-check.sh" arm \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" 're-arm with a failing register exit'
  case "$(cat "$repo/state/upstream-urgent.check.sh")" in
    *"$second_bin"*) fail 'a failed re-arm left the shim it was writing in place' ;;
  esac
  [ "$(cat "$repo/state/upstream-urgent.check.sh")" = "$before" ] \
    || fail 'a failed re-arm did not restore the shim the home was armed with'
  # The binding written by the first arm is the one that must still cover the
  # restored bytes; re-running the registrar would rewrite it and prove nothing.
  fm_custom_check_registered "$repo/state" upstream-urgent \
    || fail 'a failed re-arm left the previously armed home unbound'
  pass 'a failed re-arm restores the shim a working home was armed with'
}

test_matching_upstream_commit_is_reported
test_matching_upstream_body_is_reported
test_record_separator_in_body_keeps_commit_identity
test_control_bytes_are_removed_from_subjects
test_utf8_subject_truncation_preserves_character_boundaries
test_nonmatching_upstream_commit_is_silent
test_unusable_inspection_does_not_wake_watcher
test_recorded_base_is_excluded_from_the_range
test_check_uses_one_fetch_and_finishes_quickly
test_slow_fetch_is_bounded_before_ten_seconds
test_slow_local_scan_is_bounded_before_ten_seconds
test_check_fits_inside_configured_watcher_timeout
test_timeout_parser_accepts_decimal_values_without_overflow
test_noncanonical_upstream_remote_is_rejected
test_fatal_merge_base_failure_is_retryable
test_arm_registers_and_disarm_removes_the_check
test_arm_rejects_a_symlinked_state_parent
test_arm_rejects_a_trailing_slash_state_symlink
test_disarm_reports_cleanup_failure
test_disarm_rejects_missing_state
test_disarm_rejects_symlinked_state
test_base_is_read_from_a_row_that_also_names_a_landing_hash
test_unchanged_match_set_is_reported_once
test_disarm_removes_the_report_record
test_symlinked_record_does_not_suppress_a_hit
test_hardlinked_record_does_not_suppress_a_hit
test_nonprivate_record_does_not_suppress_a_hit
test_malformed_record_does_not_suppress_a_hit
test_record_directory_is_not_used_as_record_target
test_dangling_state_symlink_is_not_created
test_inspection_failure_is_reported_on_stderr_once
test_a_retryable_failure_never_reaches_stdout
test_a_failed_registration_leaves_no_unregistered_shim
test_a_failed_rearm_restores_the_armed_shim
test_an_interrupting_report_does_not_reannounce_an_unchanged_hit
test_a_reintroduced_unusable_tripwire_is_news_again
