#!/usr/bin/env bash
# Behavior tests for the inherited-config deviation record.
#
# Inheritance stays primary-authoritative: a secondmate home keeps its own value
# for a deviable item only while it holds an explicit evidence-backed deviation
# record, and that divergence is reported to the primary at every sync.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-config-deviation)

# Only the runtime backend is inherited here, so each case reads one item.
export FM_INHERITABLE_CONFIG=backend

new_home_pair() {  # <name> -> "<primary>|<second>"
  local name=$1 base primary second
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  second="$base/second"
  mkdir -p "$primary/config" "$primary/data" "$second/config" "$second/data"
  printf '%s\n' "$primary|$second"
}

converge() {  # <primary> <second> <report> -> stdout of the propagation
  FM_CONFIG_INHERIT_REPORT="$3" propagate_inheritable_config "$1/config" "$2/config"
}

test_deviation_is_honored_and_surfaced() {
  local rec primary second report out
  rec=$(new_home_pair honored)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  printf 'tmux\n' > "$second/config/backend"
  printf '%s\n' "four workers died on herdr 2026-08-23; tmux verified" \
    > "$second/config/backend.deviation"
  report="$TMP_ROOT/honored.report"

  out=$(converge "$primary" "$second" "$report")

  [ "$(cat "$second/config/backend")" = tmux ] \
    || fail "honored deviation was reverted to the primary value"
  assert_contains "$out" "SECONDMATE_SYNC:" "divergence must reach the primary as a sync line"
  assert_contains "$out" "config/backend held locally" "divergence line must name the item"
  assert_contains "$out" '"tmux"' "divergence line must name the local value"
  assert_contains "$out" '"herdr"' "divergence line must name the primary value"
  assert_contains "$out" "four workers died on herdr" "divergence line must carry the evidence"
  assert_grep $'backend\tdeviated\t' "$report" "report must record the deviation"
  pass "an evidence-backed deviation is honored and reported at sync time"
}

test_deviation_reported_every_sync() {
  local rec primary second report out
  rec=$(new_home_pair repeated)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  printf 'tmux\n' > "$second/config/backend"
  printf '%s\n' "verified backend pin" > "$second/config/backend.deviation"
  report="$TMP_ROOT/repeated.report"

  converge "$primary" "$second" "$report" >/dev/null
  : > "$report"
  out=$(converge "$primary" "$second" "$report")

  assert_contains "$out" "config/backend held locally" \
    "a standing divergence must stay visible on later syncs"
  [ "$(cat "$second/config/backend")" = tmux ] || fail "later sync reverted the deviation"
  pass "a standing divergence is reported at every sync, not only the first"
}

test_agreeing_deviation_stays_quiet() {
  local rec primary second report out
  rec=$(new_home_pair agreeing)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'tmux\n' > "$primary/config/backend"
  printf 'tmux\n' > "$second/config/backend"
  printf '%s\n' "verified backend pin" > "$second/config/backend.deviation"
  report="$TMP_ROOT/agreeing.report"

  out=$(converge "$primary" "$second" "$report")

  [ -z "$out" ] || fail "a dormant record diverges from nothing and must stay quiet: $out"
  assert_grep $'backend\tunchanged\t' "$report" "an agreeing item is unchanged"
  pass "a record that diverges from nothing reports nothing"
}

test_primary_revokes_by_removing_the_record() {
  local rec primary second report out
  rec=$(new_home_pair revoke)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  printf 'tmux\n' > "$second/config/backend"
  printf '%s\n' "verified backend pin" > "$second/config/backend.deviation"
  report="$TMP_ROOT/revoke.report"
  converge "$primary" "$second" "$report" >/dev/null
  [ "$(cat "$second/config/backend")" = tmux ] || fail "setup: deviation was not honored"

  rm -f "$second/config/backend.deviation"
  : > "$report"
  out=$(converge "$primary" "$second" "$report")

  [ "$(cat "$second/config/backend")" = herdr ] \
    || fail "revoking the record did not restore primary authority"
  [ -z "$out" ] || fail "an ordinary converged push must stay quiet: $out"
  assert_grep $'backend\tpushed\t' "$report" "revoked item converges as an ordinary push"
  pass "removing the record returns the item to the primary value"
}

test_record_without_evidence_is_refused() {
  local rec primary second report out
  rec=$(new_home_pair no-evidence)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  printf 'tmux\n' > "$second/config/backend"
  printf '   \n\n' > "$second/config/backend.deviation"
  report="$TMP_ROOT/no-evidence.report"

  out=$(converge "$primary" "$second" "$report")

  [ "$(cat "$second/config/backend")" = herdr ] \
    || fail "a record with no evidence must not hold the local value"
  assert_contains "$out" "deviation record rejected" "a refused record must be reported"
  assert_contains "$out" "no evidence" "the rejection must name the missing evidence"
  pass "a deviation record with no evidence line is refused, loudly"
}

test_record_for_a_non_deviable_item_is_refused() {
  local rec primary second report out
  rec=$(new_home_pair not-deviable)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'codex\n' > "$primary/config/crew-harness"
  printf 'claude\n' > "$second/config/crew-harness"
  printf '%s\n' "local harness preference" > "$second/config/crew-harness.deviation"
  report="$TMP_ROOT/not-deviable.report"

  out=$(FM_INHERITABLE_CONFIG=crew-harness converge "$primary" "$second" "$report")

  [ "$(cat "$second/config/crew-harness")" = codex ] \
    || fail "only declared deviable items may hold a local value"
  assert_contains "$out" "deviation record rejected" \
    "a record on a non-deviable item must be reported, never ignored"
  pass "a record beside a non-deviable item is refused, loudly"
}

test_unsafe_held_values_are_refused() {
  local rec primary second report out status linked

  rec=$(new_home_pair symlink-value)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  linked="$TMP_ROOT/symlink-value-target"
  printf 'tmux\n' > "$linked"
  ln -s "$linked" "$second/config/backend"
  printf '%s\n' "verified backend pin" > "$second/config/backend.deviation"
  report="$TMP_ROOT/symlink-value.report"

  out=$(converge "$primary" "$second" "$report") \
    || fail "symlinked held value did not follow normal convergence"
  assert_contains "$out" "deviation record rejected" \
    "a symlinked held value must be reported as rejected"
  assert_contains "$out" "held value is a symlink" \
    "the rejection must name the unsafe held value"
  [ ! -L "$second/config/backend" ] \
    || fail "normal convergence preserved the symlinked held value"
  [ "$(cat "$second/config/backend")" = herdr ] \
    || fail "normal convergence did not restore the primary value over a symlink"
  [ "$(cat "$linked")" = tmux ] \
    || fail "normal convergence changed the symlink target"

  rec=$(new_home_pair directory-value)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  mkdir "$second/config/backend"
  printf '%s\n' "verified backend pin" > "$second/config/backend.deviation"
  report="$TMP_ROOT/directory-value.report"

  status=0
  out=$(converge "$primary" "$second" "$report" 2>&1) || status=$?
  expect_code 1 "$status" "normal convergence over a directory-valued item"
  assert_contains "$out" "deviation record rejected" \
    "a non-ordinary held value must be reported as rejected"
  assert_contains "$out" "held value is not an ordinary file" \
    "the rejection must name the non-ordinary held value"
  assert_grep $'backend\terror\tfailed to copy' "$report" \
    "normal convergence must retain its existing non-ordinary destination error"

  rec=$(new_home_pair hardlinked-value)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'herdr\n' > "$primary/config/backend"
  linked="$TMP_ROOT/hardlinked-value-target"
  printf 'tmux\n' > "$linked"
  ln "$linked" "$second/config/backend"
  printf '%s\n' "verified backend pin" > "$second/config/backend.deviation"
  report="$TMP_ROOT/hardlinked-value.report"

  out=$(converge "$primary" "$second" "$report") \
    || fail "hardlinked held value did not follow normal convergence"
  assert_contains "$out" "held value is hardlinked" \
    "a hardlinked held value must be reported as rejected"
  [ "$(cat "$second/config/backend")" = herdr ] \
    || fail "normal convergence did not restore the primary value over a hardlink"
  [ "$(cat "$linked")" = tmux ] \
    || fail "normal convergence changed the other hardlink"
  pass "unsafe held values are rejected before normal convergence"
}

test_deviation_holds_against_primary_absence() {
  local rec primary second report out
  rec=$(new_home_pair absence)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'tmux\n' > "$second/config/backend"
  printf '%s\n' "auto-detection kills workers here" \
    > "$second/config/backend.deviation"
  report="$TMP_ROOT/absence.report"

  out=$(converge "$primary" "$second" "$report")

  [ "$(cat "$second/config/backend")" = tmux ] \
    || fail "absence mirroring erased an honored deviation"
  assert_contains "$out" "against primary absence" \
    "the divergence line must name that the primary holds no value"
  pass "a deviation also holds against the primary's absence"
}

test_remote_receiver_honors_the_record() {
  local home payload out
  home="$TMP_ROOT/remote/home"
  mkdir -p "$home/config" "$home/state"
  printf 'tmux\n' > "$home/config/backend"
  printf '%s\n' "verified backend pin" > "$home/config/backend.deviation"
  payload="$TMP_ROOT/remote/payload"
  mkdir -p "$TMP_ROOT/remote"
  printf 'herdr\n' > "$payload"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" put config/backend \
    "$(LC_ALL=C wc -c < "$payload" | tr -d ' ')" \
    "$(fm_inherit_sha256 "$payload")" 1 < "$payload") \
    || fail "remote receiver failed on a deviated item"

  [ "$(cat "$home/config/backend")" = tmux ] \
    || fail "remote convergence reverted an honored deviation"
  assert_contains "$out" "deviation: config/backend" \
    "the remote receiver must report the divergence to the pushing primary"
  assert_contains "$out" 'held locally at "tmux" against primary "herdr"' \
    "the remote divergence must carry both bounded values"

  # Control: with the record gone the same receiver converges as it always did,
  # so honoring a deviation never becomes the remote path's default.
  rm -f "$home/config/backend.deviation"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" put config/backend \
    "$(LC_ALL=C wc -c < "$payload" | tr -d ' ')" \
    "$(fm_inherit_sha256 "$payload")" 2 < "$payload") \
    || fail "remote receiver failed on an ordinary item"
  [ "$(cat "$home/config/backend")" = herdr ] \
    || fail "remote convergence stopped applying the primary value"
  assert_contains "$out" "pushed: config/backend" "an ordinary remote push still reports pushed"
  pass "a remote home's deviation record is honored and reported too"
}

test_remote_receiver_agreement_stays_quiet() {
  local home payload out empty_hash
  home="$TMP_ROOT/remote-agreeing/home"
  mkdir -p "$home/config"
  printf 'tmux\n' > "$home/config/backend"
  printf '%s\n' "verified backend pin" > "$home/config/backend.deviation"
  payload="$TMP_ROOT/remote-agreeing/payload"
  printf 'tmux\n' > "$payload"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" put config/backend \
    "$(LC_ALL=C wc -c < "$payload" | tr -d ' ')" \
    "$(fm_inherit_sha256 "$payload")" 1 < "$payload") \
    || fail "remote receiver failed on an agreeing value"
  assert_contains "$out" "unchanged: config/backend" \
    "an agreeing remote value must retain the ordinary unchanged result"
  assert_not_contains "$out" "deviation:" \
    "an agreeing remote value must not report a divergence"

  rm -f "$home/config/backend"
  empty_hash=$(printf '' | fm_inherit_sha256 /dev/stdin)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" absent config/backend \
    0 "$empty_hash" 2 < /dev/null) \
    || fail "remote receiver failed on agreeing absence"
  assert_contains "$out" "unchanged: config/backend" \
    "agreeing remote absence must retain the ordinary unchanged result"
  assert_not_contains "$out" "deviation:" \
    "agreeing remote absence must not report a divergence"
  pass "a remote deviation record stays quiet when values agree"
}

test_remote_receiver_reports_primary_absence() {
  local home out empty_hash
  home="$TMP_ROOT/remote-absence/home"
  mkdir -p "$home/config"
  printf 'tmux\n' > "$home/config/backend"
  printf '%s\n' "verified backend pin" > "$home/config/backend.deviation"
  empty_hash=$(printf '' | fm_inherit_sha256 /dev/stdin)

  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" absent config/backend \
    0 "$empty_hash" 1 < /dev/null) \
    || fail "remote receiver failed on a deviation against primary absence"
  assert_contains "$out" 'held locally at "tmux" against primary absence' \
    "the remote divergence must name primary absence"
  [ "$(cat "$home/config/backend")" = tmux ] \
    || fail "remote primary absence erased an honored local value"
  pass "a remote divergence names primary absence"
}

test_remote_deviation_relay_survives_later_failure() {
  local out
  out=$(printf '%s\n' \
    'unchanged: config/crew-harness' \
    'deviation: config/backend held locally at "tmux" against primary "herdr": verified' \
    'error: later item failed' \
    | fm_config_relay_remote_deviations ios)
  assert_contains "$out" \
    'SECONDMATE_SYNC: secondmate ios: deviation: config/backend held locally at "tmux" against primary "herdr": verified' \
    "the primary relay must preserve a divergence before a later failure"
  assert_not_contains "$out" "later item failed" \
    "the divergence relay must not misclassify ordinary remote output"
  pass "remote divergence relay is independent of overall push success"
}

test_remote_receiver_commits_honored_generation() {
  local home newer older out status
  home="$TMP_ROOT/remote-generation/home"
  mkdir -p "$home/config"
  printf 'tmux\n' > "$home/config/backend"
  printf '%s\n' "verified backend pin" > "$home/config/backend.deviation"
  newer="$TMP_ROOT/remote-generation/newer"
  older="$TMP_ROOT/remote-generation/older"
  printf 'herdr\n' > "$newer"
  printf 'orca\n' > "$older"

  FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" put config/backend \
    "$(LC_ALL=C wc -c < "$newer" | tr -d ' ')" \
    "$(fm_inherit_sha256 "$newer")" 2 < "$newer" >/dev/null \
    || fail "remote receiver failed on the newer deviated generation"

  rm -f "$home/config/backend.deviation"
  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" put config/backend \
    "$(LC_ALL=C wc -c < "$older" | tr -d ' ')" \
    "$(fm_inherit_sha256 "$older")" 1 < "$older" 2>&1) || status=$?

  expect_code 1 "$status" "a delayed older generation after deviation revocation"
  assert_contains "$out" "generation is superseded" \
    "the delayed generation must be rejected by the replay barrier"
  [ "$(cat "$home/config/backend")" = tmux ] \
    || fail "a delayed older generation replaced the formerly deviated value"
  pass "an honored remote deviation still advances the replay barrier"
}

test_deviation_is_honored_and_surfaced
test_deviation_reported_every_sync
test_agreeing_deviation_stays_quiet
test_primary_revokes_by_removing_the_record
test_record_without_evidence_is_refused
test_record_for_a_non_deviable_item_is_refused
test_unsafe_held_values_are_refused
test_deviation_holds_against_primary_absence
test_remote_receiver_honors_the_record
test_remote_receiver_agreement_stays_quiet
test_remote_receiver_reports_primary_absence
test_remote_deviation_relay_survives_later_failure
test_remote_receiver_commits_honored_generation
