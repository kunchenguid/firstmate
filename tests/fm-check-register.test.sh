#!/usr/bin/env bash
# Behavior tests for fm-check-register.sh: registration must leave a check the
# watcher will run (mode 0700 plus a matching trust record), or refuse loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-register)
PERL=$(command -v perl) || fail "fm-check-register requires perl"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_mode_0600_check_is_normalized_and_registered() {
  local home out status
  home=$(make_home mode600)
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
  chmod 0600 "$home/state/poll.check.sh"
  out=$(FM_HOME="$home" "$REGISTER" poll 2>&1); status=$?
  [ "$status" -eq 0 ] || fail "registering a mode 0600 check failed: $out"
  [ "$(fm_pr_file_mode "$home/state/poll.check.sh")" = 700 ] || fail "check was not set to mode 0700"
  fm_custom_check_registered "$home/state" poll || fail "armed check is not registered with a matching trust hash"
  pass "mode 0600 check is normalized to 0700 and registered"
}

test_unsafe_check_is_refused_naming_the_check() {
  local home err status
  home=$(make_home hardlink)
  printf '#!/usr/bin/env bash\n' > "$home/state/poll.check.sh"
  chmod 0600 "$home/state/poll.check.sh"
  ln "$home/state/poll.check.sh" "$home/other.check.sh"
  err=$(FM_HOME="$home" "$REGISTER" poll 2>&1 >/dev/null); status=$?
  [ "$status" -eq 1 ] || fail "hard-linked check was not refused (status $status)"
  assert_contains "$err" "state/poll.check.sh" "refusal did not name the check"
  assert_contains "$err" "not registered" "refusal did not say the check is unregistered"
  [ ! -e "$home/state/poll.check-trust" ] || fail "refused check left a trust record"
  [ "$(fm_pr_file_mode "$home/state/poll.check.sh")" = 600 ] || fail "refused check had its mode changed"
  [ "$(fm_pr_file_mode "$home/other.check.sh")" = 600 ] || fail "refused check's other link had its mode changed"
  pass "unsafe check is refused loudly and names the check"
}

test_check_swapped_to_symlink_during_normalization_does_not_touch_target() {
  local home target fakebin err status
  home=$(make_home symlink-race)
  target="$home/target"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
  printf target > "$target"
  chmod 0600 "$home/state/poll.check.sh" "$target"
  cat > "$fakebin/perl" <<EOF
#!/usr/bin/env bash
mv "$home/state/poll.check.sh" "$home/state/original.check.sh"
ln -s "$target" "$home/state/poll.check.sh"
exec "$PERL" "\$@"
EOF
  chmod 0700 "$fakebin/perl"
  err=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" poll 2>&1 >/dev/null); status=$?
  [ "$status" -eq 1 ] || fail "symlink swap during normalization was not refused (status $status)"
  [ "$(fm_pr_file_mode "$target")" = 600 ] || fail "symlink swap changed the target mode"
  [ ! -e "$home/state/poll.check-trust" ] || fail "refused symlink swap left a trust record"
  pass "normalization does not follow a swapped check symlink"
}

test_check_swapped_to_hardlink_during_normalization_does_not_touch_target() {
  local home target fakebin out status
  home=$(make_home hardlink-race)
  target="$home/target"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
  printf '#!/usr/bin/env bash\nprintf target\\n\n' > "$target"
  chmod 0600 "$home/state/poll.check.sh" "$target"
  cat > "$fakebin/perl" <<EOF
#!/usr/bin/env bash
mv "$home/state/poll.check.sh" "$home/state/original.check.sh"
ln "$target" "$home/state/poll.check.sh"
exec "$PERL" "\$@"
EOF
  chmod 0700 "$fakebin/perl"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" poll 2>&1); status=$?
  [ "$(fm_pr_file_mode "$target")" = 600 ] || fail "hard-link swap changed the target mode"
  [ "$status" -eq 0 ] || fail "hard-link swap during normalization was not recovered: $out"
  [ "$(fm_pr_file_mode "$home/state/poll.check.sh")" = 700 ] || fail "published check was not set to mode 0700"
  fm_custom_check_registered "$home/state" poll || fail "published check was not registered"
  pass "normalization does not chmod a swapped hard-link target"
}

test_mode_0600_check_is_normalized_and_registered
test_unsafe_check_is_refused_naming_the_check
test_check_swapped_to_symlink_during_normalization_does_not_touch_target
test_check_swapped_to_hardlink_during_normalization_does_not_touch_target
