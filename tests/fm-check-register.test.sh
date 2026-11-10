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
  out=$(umask 0700; FM_HOME="$home" "$REGISTER" poll 2>&1); status=$?
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

test_check_swapped_to_fifo_during_normalization_is_refused() {
  local home fakebin err status
  home=$(make_home fifo-race)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
  chmod 0600 "$home/state/poll.check.sh"
  cat > "$fakebin/perl" <<EOF
#!/usr/bin/env bash
mv "$home/state/poll.check.sh" "$home/state/original.check.sh"
mkfifo "$home/state/poll.check.sh"
exec "$PERL" "\$@"
EOF
  chmod 0700 "$fakebin/perl"
  err=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" poll 2>&1 >/dev/null); status=$?
  [ "$status" -eq 1 ] || fail "FIFO swap during normalization was not refused: $err"
  [ ! -e "$home/state/poll.check-trust" ] || fail "refused FIFO swap left a trust record"
  pass "normalization refuses a swapped FIFO input"
}

test_check_swapped_to_hardlink_during_normalization_is_refused() {
  local home target fakebin err status
  home=$(make_home hardlink-race)
  target="$home/target"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
  printf '#!/usr/bin/env bash\nprintf target\\n\n' > "$target"
  chmod 0600 "$home/state/poll.check.sh" "$target"
  cat > "$fakebin/perl" <<EOF
#!/usr/bin/env bash
if [ ! -e "$home/swapped" ]; then
  mv "$home/state/poll.check.sh" "$home/state/original.check.sh"
  ln "$target" "$home/state/poll.check.sh"
  : > "$home/swapped"
fi
exec "$PERL" "\$@"
EOF
  chmod 0700 "$fakebin/perl"
  err=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" poll 2>&1 >/dev/null); status=$?
  [ "$(fm_pr_file_mode "$target")" = 600 ] || fail "hard-link swap changed the target mode"
  [ "$status" -eq 1 ] || fail "hard-link swap during normalization was not refused: $err"
  [ ! -e "$home/state/poll.check-trust" ] || fail "refused hard-link swap left a trust record"
  pass "normalization refuses a swapped hard-link input"
}

# Put a perl on PATH that pauses when the normalization worker opens the check
# for reading, i.e. after File::Temp created the temp and before the copy: it
# writes $home/paused and waits for $home/go, so a test can act on the
# generated temp deterministically.
install_pausing_perl() {
  local home=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin" "$home/fakelib"
  cat > "$home/fakelib/FmPause.pm" <<'PM'
package FmPause;
BEGIN {
  *CORE::GLOBAL::sysopen = sub (*$$;$) {
    goto &CORE::sysopen unless defined $ARGV[0] && $_[1] eq $ARGV[0];
    open(my $mark, '>', "$ENV{FM_PAUSE_DIR}/paused") or die;
    close $mark;
    select(undef, undef, undef, 0.01) until -e "$ENV{FM_PAUSE_DIR}/go";
    return @_ > 3 ? CORE::sysopen($_[0], $_[1], $_[2], $_[3]) : CORE::sysopen($_[0], $_[1], $_[2]);
  };
}
1;
PM
  cat > "$fakebin/perl" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$home/perl.pid.tmp" && mv "$home/perl.pid.tmp" "$home/perl.pid"
exec "$PERL" -I"$home/fakelib" -MFmPause "\$@"
WRAP
  chmod 0700 "$fakebin/perl"
}

wait_for_file() {
  local n
  for n in {1..1000}; do
    [ -e "$1" ] && return 0
    sleep 0.01
  done
  return 1
}

test_generated_temp_hardlink_swap_does_not_touch_target() {
  local home target temp status pid
  home=$(make_home generated-hardlink-race)
  target="$home/target"
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
  printf victim > "$target"
  chmod 0600 "$home/state/poll.check.sh" "$target"
  install_pausing_perl "$home"
  PATH="$home/fakebin:$PATH" FM_PAUSE_DIR="$home" FM_HOME="$home" "$REGISTER" poll >/dev/null 2>&1 &
  pid=$!
  wait_for_file "$home/paused" || fail "normalization worker did not pause"
  temp=$(find "$home/state" -name '.fm-custom-check.*' | head -n 1)
  [ -n "$temp" ] || fail "normalization temp was not created"
  rm -f -- "$temp"
  ln "$target" "$temp" || fail "could not hard-link the victim over the temp"
  : > "$home/go"
  wait "$pid"; status=$?
  [ "$status" -eq 1 ] || fail "generated-temp hard-link swap was not refused"
  [ "$(cat "$target")" = victim ] || fail "generated-temp hard-link swap changed the target bytes"
  [ "$(fm_pr_file_mode "$target")" = 600 ] || fail "generated-temp hard-link swap changed the target mode"
  [ ! -e "$home/state/poll.check-trust" ] || fail "refused generated-temp swap left a trust record"
  [ -z "$(find "$home/state" -name '.fm-custom-check*' 2>/dev/null)" ] \
    || fail "generated-temp hard-link swap left a temporary check copy"
  pass "generated temp hard-link swap is refused without touching target"
}

test_interrupted_normalization_leaves_no_temporary_copy() {
  local home sig status pid
  for sig in TERM HUP; do
    home=$(make_home "interrupt-$sig")
    printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$home/state/poll.check.sh"
    chmod 0600 "$home/state/poll.check.sh"
    install_pausing_perl "$home"
    PATH="$home/fakebin:$PATH" FM_PAUSE_DIR="$home" FM_HOME="$home" "$REGISTER" poll >/dev/null 2>&1 &
    pid=$!
    wait_for_file "$home/paused" || fail "normalization worker did not pause ($sig)"
    wait_for_file "$home/perl.pid" || fail "perl worker did not start ($sig)"
    kill -"$sig" "$(cat "$home/perl.pid")"
    wait "$pid"; status=$?
    [ "$status" -ne 0 ] || fail "$sig during normalization did not stop registration"
    [ -z "$(find "$home/state" -name '.fm-custom-check*' 2>/dev/null)" ] \
      || fail "$sig during normalization left a temporary check copy"
    [ ! -e "$home/state/poll.check-trust" ] || fail "interrupted registration left a trust record"
  done
  pass "interrupted normalization leaves no temporary check copy"
}

test_mode_0600_check_is_normalized_and_registered
test_interrupted_normalization_leaves_no_temporary_copy
test_unsafe_check_is_refused_naming_the_check
test_check_swapped_to_symlink_during_normalization_does_not_touch_target
test_check_swapped_to_fifo_during_normalization_is_refused
test_check_swapped_to_hardlink_during_normalization_is_refused
test_generated_temp_hardlink_swap_does_not_touch_target
