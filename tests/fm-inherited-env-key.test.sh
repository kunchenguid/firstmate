#!/usr/bin/env bash
# Behavior tests for secret-class .env key inheritance.
#
# The primary's TYPESAFE_API_KEY line converges into each local secondmate
# home's .env at mode 600; every other .env line stays per-home, the value
# never reaches a report or diagnostic, and the remote route refuses the key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-inherited-env-key)

fm_git_identity fmtest fmtest@example.invalid

PRIMARY_KEY_VALUE="ts-primary-secret-value"
SECOND_KEY_VALUE="ts-second-stale-value"
ITEM=".env:TYPESAFE_API_KEY"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

new_home_pair() {
  local name=$1 base primary second
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  second="$base/second"
  mkdir -p "$primary/data" "$primary/config" "$second/data" "$second/config"
  printf '%s\n' "$primary|$second"
}

assert_value_absent() {
  local path=$1 what=$2
  assert_no_grep "$PRIMARY_KEY_VALUE" "$path" "$what leaked the primary key value"
  assert_no_grep "$SECOND_KEY_VALUE" "$path" "$what leaked the secondmate key value"
}

test_key_line_converges_and_other_env_lines_stay_per_home() {
  local rec primary second report err
  rec=$(new_home_pair converge)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'FMX_PAIRING_TOKEN=primary-relay\nexport TYPESAFE_API_KEY="%s"\n' "$PRIMARY_KEY_VALUE" > "$primary/.env"
  printf 'FMX_PAIRING_TOKEN=second-relay\nTYPESAFE_API_KEY=%s\nMAIL_HOST=imap.example.invalid\n' "$SECOND_KEY_VALUE" > "$second/.env"
  chmod 644 "$second/.env"
  report="$TMP_ROOT/converge.report"
  err="$TMP_ROOT/converge.err"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err" \
    || fail "convergence should succeed"

  assert_grep $'.env:TYPESAFE_API_KEY\tpushed\t' "$report" "first convergence should report the key pushed"
  assert_grep 'export TYPESAFE_API_KEY="'"$PRIMARY_KEY_VALUE"'"' "$second/.env" \
    "primary key line should be carried verbatim"
  assert_no_grep "$SECOND_KEY_VALUE" "$second/.env" "stale secondmate key line should be replaced"
  [ "$(grep -c 'TYPESAFE_API_KEY=' "$second/.env")" -eq 1 ] || fail "key should appear exactly once after convergence"
  assert_grep 'FMX_PAIRING_TOKEN=second-relay' "$second/.env" "secondmate Relay token must stay per-home"
  assert_grep 'MAIL_HOST=imap.example.invalid' "$second/.env" "secondmate mail line must stay per-home"
  [ "$(sed -n 2p "$second/.env")" = 'export TYPESAFE_API_KEY="'"$PRIMARY_KEY_VALUE"'"' ] \
    || fail "replacement should keep the key line's original position"
  [ "$(file_mode "$second/.env")" = 600 ] || fail "converged .env should be mode 600, got $(file_mode "$second/.env")"
  assert_value_absent "$report" "propagation report"
  assert_value_absent "$err" "stderr"
  assert_grep 'FMX_PAIRING_TOKEN=primary-relay' "$primary/.env" "primary .env must not change"

  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "repeated convergence should succeed"
  assert_grep $'.env:TYPESAFE_API_KEY\tunchanged\t' "$report" "converged key should report unchanged"
  pass "primary key line converges in place at mode 600 and leaves other .env lines per-home"
}

test_identical_destination_line_restores_mode_and_reports_unchanged() {
  local rec primary second report err
  rec=$(new_home_pair identical-mode)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$primary/.env"
  printf 'FMX_PAIRING_TOKEN=second-relay\nTYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$second/.env"
  chmod 644 "$second/.env"
  report="$TMP_ROOT/identical-mode.report"
  err="$TMP_ROOT/identical-mode.err"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err" \
    || fail "convergence over an identical hand-copied line should succeed"

  assert_grep $'.env:TYPESAFE_API_KEY\tunchanged\trestored mode 600' "$report" \
    "identical bytes at a loose mode should report unchanged with the mode restored"
  assert_no_grep $'.env:TYPESAFE_API_KEY\tpushed' "$report" "identical bytes must not report pushed"
  [ "$(file_mode "$second/.env")" = 600 ] || fail "identical hand-copied .env should be tightened to 600, got $(file_mode "$second/.env")"
  [ "$(cat "$second/.env")" = "FMX_PAIRING_TOKEN=second-relay
TYPESAFE_API_KEY=$PRIMARY_KEY_VALUE" ] || fail "identical destination bytes must not change"
  assert_value_absent "$report" "propagation report"
  assert_value_absent "$err" "stderr"

  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "repeated convergence should succeed"
  grep -qx $'.env:TYPESAFE_API_KEY\tunchanged\t' "$report" || fail "already-600 identical destination should report plain unchanged"
  pass "identical destination line at mode 644 converges to 600 and reports unchanged"
}

test_unreadable_primary_env_is_an_error_and_keeps_destination() {
  local rec primary second report err
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable primary .env case skipped: running as root"
    return 0
  fi
  rec=$(new_home_pair unreadable)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$primary/.env"
  printf 'FMX_PAIRING_TOKEN=second-relay\nTYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$second/.env"
  chmod 600 "$second/.env"
  chmod 000 "$primary/.env"
  report="$TMP_ROOT/unreadable.report"
  err="$TMP_ROOT/unreadable.err"

  if FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; then
    chmod 600 "$primary/.env"
    fail "an unreadable primary .env must make convergence fail"
  fi
  chmod 600 "$primary/.env"

  assert_grep $'.env:TYPESAFE_API_KEY\terror\tcannot inspect primary .env' "$report" \
    "unreadable primary .env should report an inspection error for the key"
  assert_no_grep $'.env:TYPESAFE_API_KEY\tpushed' "$report" "unreadable primary .env must not be mirrored as absence"
  [ "$(cat "$second/.env")" = "FMX_PAIRING_TOKEN=second-relay
TYPESAFE_API_KEY=$PRIMARY_KEY_VALUE" ] || fail "destination key line must survive an unreadable primary .env"
  [ "$(file_mode "$second/.env")" = 600 ] || fail "destination .env should stay mode 600"
  assert_value_absent "$report" "propagation report"
  assert_value_absent "$err" "stderr"
  pass "unreadable primary .env reports an error and leaves the destination key line in place"
}

test_absent_primary_key_removes_line_and_missing_files_are_quiet() {
  local rec primary second report
  rec=$(new_home_pair absence)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'FMX_PAIRING_TOKEN=primary-relay\n' > "$primary/.env"
  printf 'TYPESAFE_API_KEY=%s\nFMX_PAIRING_TOKEN=second-relay\n' "$SECOND_KEY_VALUE" > "$second/.env"
  chmod 600 "$second/.env"
  report="$TMP_ROOT/absence.report"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "absence convergence should succeed"

  assert_grep $'.env:TYPESAFE_API_KEY\tpushed\tmirrored primary absence' "$report" \
    "primary absence should report a mirrored removal"
  assert_no_grep 'TYPESAFE_API_KEY' "$second/.env" "primary absence should remove the secondmate key line"
  assert_grep 'FMX_PAIRING_TOKEN=second-relay' "$second/.env" "removal must keep the per-home Relay token"
  [ "$(file_mode "$second/.env")" = 600 ] || fail "rewritten .env should stay mode 600"

  : > "$report"
  rm -f "$primary/.env"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "missing primary .env should be a quiet no-op"
  assert_grep $'.env:TYPESAFE_API_KEY\tunchanged\t' "$report" "missing primary .env with no destination key should report unchanged"

  : > "$report"
  rm -f "$second/.env"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "both files missing should be a quiet no-op"
  assert_grep $'.env:TYPESAFE_API_KEY\tunchanged\t' "$report" "both files missing should report unchanged"
  assert_absent "$second/.env" "absence on both sides must not create a destination .env"

  : > "$report"
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$primary/.env"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "creating a destination .env should succeed"
  assert_grep $'.env:TYPESAFE_API_KEY\tpushed\t' "$report" "a new destination .env should report pushed"
  [ "$(cat "$second/.env")" = "TYPESAFE_API_KEY=$PRIMARY_KEY_VALUE" ] || fail "new destination .env should hold only the key line"
  [ "$(file_mode "$second/.env")" = 600 ] || fail "new destination .env should be mode 600"
  pass "primary absence removes only the key line, and absent files converge quietly"
}

test_unsafe_env_artifacts_are_rejected_without_leaking() {
  local rec primary second report err rc
  rec=$(new_home_pair unsafe)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$primary/real.env"
  ln -s "$primary/real.env" "$primary/.env"
  report="$TMP_ROOT/unsafe.report"
  err="$TMP_ROOT/unsafe.err"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked primary .env should be rejected"
  assert_grep $'.env:TYPESAFE_API_KEY\terror\tprimary .env is not a regular file' "$report" \
    "symlinked primary source should report an error"
  assert_absent "$second/.env" "rejected source must not create a destination"
  assert_value_absent "$err" "unsafe-source stderr"
  rm -f "$primary/.env"
  mv "$primary/real.env" "$primary/.env"

  : > "$report"
  printf 'TYPESAFE_API_KEY=%s\n' "$SECOND_KEY_VALUE" > "$second/real.env"
  ln -s "$second/real.env" "$second/.env"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked destination .env should be rejected"
  assert_grep $'.env:TYPESAFE_API_KEY\terror\tunsafe destination' "$report" \
    "symlinked destination should report an error"
  assert_grep "$SECOND_KEY_VALUE" "$second/real.env" "rejected destination must be left untouched"
  assert_value_absent "$err" "unsafe-destination stderr"
  rm -f "$second/.env" "$second/real.env"

  : > "$report"
  printf 'TYPESAFE_API_KEY=%s\n' "$SECOND_KEY_VALUE" > "$second/.env"
  ln "$second/.env" "$second/hardlink-copy"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked destination .env should be rejected"
  assert_grep $'.env:TYPESAFE_API_KEY\terror\tunsafe destination' "$report" \
    "hardlinked destination should report an error"
  pass "symlinked and hardlinked .env artifacts are rejected without leaking a value"
}

test_tracked_env_destination_is_skipped() {
  local rec primary second report err
  rec=$(new_home_pair tracked)
  primary=${rec%%|*}
  second=${rec#*|}
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$primary/.env"
  git init -q -b main "$second"
  printf '%s\n' "tracked" > "$second/.env"
  git -C "$second" add .env
  git -C "$second" commit -qm "track env"
  report="$TMP_ROOT/tracked.report"
  err="$TMP_ROOT/tracked.err"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err" \
    || fail "a skipped tracked destination is a warning, not a failure"

  assert_grep $'.env:TYPESAFE_API_KEY\tskipped\t' "$report" "a tracked destination .env should be skipped"
  [ "$(cat "$second/.env")" = tracked ] || fail "skipped destination must be left untouched"
  assert_value_absent "$err" "skip stderr"

  printf '%s\n' ".env" > "$second/.gitignore"
  git -C "$second" rm -q --cached .env
  git -C "$second" add .gitignore
  git -C "$second" commit -qm "ignore env"
  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>&1 \
    || fail "an ignored destination should converge"
  assert_grep $'.env:TYPESAFE_API_KEY\tpushed\t' "$report" "an ignored destination .env should be pushed"
  assert_grep "TYPESAFE_API_KEY=$PRIMARY_KEY_VALUE" "$second/.env" "ignored destination should receive the key"
  pass "a tracked destination .env is skipped and an ignored one converges"
}

new_git_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  {
    printf '%s\n' '.env'
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'data/'
    printf '%s\n' 'state/'
    printf '%s\n' 'config/'
    printf '%s\n' 'projects/'
  } > "$root/.gitignore"
  printf '%s\n' "instructions" > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' "echo spawn" > "$root/bin/fm-spawn.sh"
  printf '%s\n' "skill" > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/sm" "$c1"
  printf '%s\n' sm > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf '%s\n' "charter" > "$w/sm/data/charter.md"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/sm"
}

test_config_push_convergence_point_carries_key_without_reread_inline() {
  local rec w root home sm out instruction
  rec=$(new_git_world config-push-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$home/.env"
  chmod 600 "$home/.env"
  printf 'FMX_PAIRING_TOKEN=second-relay\n' > "$sm/.env"
  chmod 600 "$sm/.env"
  printf '%s\n' codex > "$home/config/crew-harness"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-config-push.sh" 2>&1)

  assert_contains "$out" "$ITEM: pushed" "config-push should report the key pushed"
  assert_contains "$out" "crew-harness: pushed" "config-push should still push config items"
  assert_not_contains "$out" "$PRIMARY_KEY_VALUE" "config-push output must never carry the key value"
  assert_grep "TYPESAFE_API_KEY=$PRIMARY_KEY_VALUE" "$sm/.env" "config-push should converge the key line"
  assert_grep 'FMX_PAIRING_TOKEN=second-relay' "$sm/.env" "config-push must keep the per-home Relay token"
  [ "$(file_mode "$sm/.env")" = 600 ] || fail "config-push should leave .env at mode 600"
  instruction=$(find "$sm/state" -maxdepth 1 -name '.fm-inherited-config-reread*' -type f | head -n1)
  [ -n "$instruction" ] || fail "changed crew-harness should have written a config-reread instruction"
  assert_grep 'crew-harness' "$instruction" "reread instruction should inline the changed config item"
  assert_no_grep 'TYPESAFE_API_KEY' "$instruction" "reread instruction must never name the secret key"
  assert_value_absent "$instruction" "config-reread instruction"
  pass "fm-config-push carries the key at mode 600 and keeps it out of the reread instruction"
}

test_remote_route_reports_key_skipped_and_never_sends_it() {
  local w home fakebin ssh_log out
  w="$TMP_ROOT/remote"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  fm_test_fake_ssh "$fakebin"
  ssh_log="$w/ssh.log"
  printf 'TYPESAFE_API_KEY=%s\n' "$PRIMARY_KEY_VALUE" > "$home/.env"
  printf -- '- far - remote fixture (host: remote-host; root: /opt/firstmate; home: /srv/fm-far; scope: fixture; projects: sample; added 2026-09-18)\n' \
    > "$home/data/secondmates.md"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_SSH_BIN="$fakebin/fake-ssh" FM_SSH_LOG="$ssh_log" \
    FM_INHERITABLE_CONFIG="crew-harness" \
    "$ROOT/bin/fm-remote-inherit-push.sh" far 1 2>&1) || fail "remote push should succeed while refusing the key: $out"

  assert_contains "$out" "skipped: $ITEM" "remote route should report the key as skipped"
  assert_not_contains "$out" "$PRIMARY_KEY_VALUE" "remote push output must never carry the key value"
  assert_present "$ssh_log" "remote push should still transfer the allowlisted items"
  assert_no_grep 'TYPESAFE_API_KEY' "$ssh_log" "remote transport must never be asked to write the key"
  assert_no_grep "$PRIMARY_KEY_VALUE" "$ssh_log" "remote transport must never see the key value"
  pass "remote inheritance refuses the key visibly and never sends it"
}

test_key_line_converges_and_other_env_lines_stay_per_home
test_identical_destination_line_restores_mode_and_reports_unchanged
test_unreadable_primary_env_is_an_error_and_keeps_destination
test_absent_primary_key_removes_line_and_missing_files_are_quiet
test_unsafe_env_artifacts_are_rejected_without_leaking
test_tracked_env_destination_is_skipped
test_config_push_convergence_point_carries_key_without_reread_inline
test_remote_route_reports_key_skipped_and_never_sends_it

echo "# all fm-inherited-env-key tests passed"
