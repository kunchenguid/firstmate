#!/usr/bin/env bash
# Behavior tests for fm-check-unregister.sh: refuse empty-variable retirement,
# and remove only the two named custom-check files on the happy path. Also
# pins fm-check-register.sh's private-mode test on a mount that cannot store
# modes (Git for Windows noacl).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNREGISTER="$ROOT/bin/fm-check-unregister.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-unregister)
REAL_RM=$(command -v rm)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_registered_check() {
  local home=$1 id=$2
  cat > "$home/state/$id.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'custom-ready\n'
SH
  chmod 0700 "$home/state/$id.check.sh"
  FM_HOME="$home" "$REGISTER" "$id" >/dev/null \
    || fail "could not register custom check $id"
}

install_rm_logger() {
  local home=$1 fakebin log
  fakebin=$(fm_fakebin "$home")
  log="$home/rm.log"
  : > "$log"
  cat > "$fakebin/rm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$REAL_RM" "\$@"
SH
  chmod +x "$fakebin/rm"
  printf '%s\n' "$log"
}

assert_rm_not_invoked() {
  local log=$1
  [ -s "$log" ] && fail "retire path invoked rm while refusing"$'\n'"--- rm log ---"$'\n'"$(cat "$log")"
}

test_empty_id_and_empty_state_refuse_without_stray_rm() {
  local home out err status log canary_empty_id canary_sibling decoy
  home=$(make_home empty-var)
  out="$home/out.txt"
  err="$home/err.txt"
  log=$(install_rm_logger "$home")
  canary_empty_id="$home/state/.check.sh"
  canary_sibling="$home/state/keep.check.sh"
  decoy="$home/decoy.check.sh"
  printf 'canary-empty-id\n' > "$canary_empty_id"
  printf 'sibling\n' > "$canary_sibling"
  printf 'decoy\n' > "$decoy"
  chmod 0700 "$canary_empty_id" "$canary_sibling"

  status=0
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    "$UNREGISTER" >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "unregister with no id"
  assert_contains "$(cat "$err")" "error:" "missing-id refusal had no stderr"
  assert_present "$canary_empty_id" "empty-id expansion deleted state/.check.sh"
  assert_present "$canary_sibling" "missing-id call deleted a sibling check file"
  assert_present "$decoy" "missing-id call deleted a decoy outside state/"
  assert_rm_not_invoked "$log"

  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    "$UNREGISTER" "" >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "unregister with empty id"
  assert_contains "$(cat "$err")" "error:" "empty-id refusal had no stderr"
  assert_present "$canary_empty_id" "empty-string id deleted state/.check.sh"
  assert_rm_not_invoked "$log"

  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    "$UNREGISTER" "../escape" >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "unregister with unsafe id"
  assert_present "$canary_empty_id" "unsafe id deleted state/.check.sh"
  assert_rm_not_invoked "$log"

  mkdir -p "$home/nostate-home"
  printf 'pre-state-canary\n' > "$home/nostate-home/.check.sh"
  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home/nostate-home" \
    "$UNREGISTER" demo-check >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister with missing state dir"
  assert_contains "$(cat "$err")" "state directory is unavailable" \
    "missing state dir refusal used the wrong stderr"
  assert_present "$home/nostate-home/.check.sh" \
    "missing-state-dir call deleted a stray path in the home"
  assert_present "$canary_empty_id" "missing-state-dir call reached another home's files"
  assert_rm_not_invoked "$log"

  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/missing-state" \
    "$UNREGISTER" demo-check >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister with empty-equivalent state override"
  assert_contains "$(cat "$err")" "state directory is unavailable" \
    "non-directory state override refusal used the wrong stderr"
  assert_present "$canary_empty_id" "bad state override deleted state/.check.sh"
  assert_present "$canary_sibling" "bad state override deleted a sibling"
  assert_rm_not_invoked "$log"

  write_registered_check "$home" override-empty
  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE='' \
    "$UNREGISTER" override-empty >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister with explicitly empty state override"
  assert_contains "$(cat "$err")" "state directory is unavailable" \
    "empty state override refusal used the wrong stderr"
  assert_present "$home/state/override-empty.check.sh" \
    "empty state override deleted the home state check"
  assert_present "$home/state/override-empty.check-trust" \
    "empty state override deleted the home state trust binding"
  assert_rm_not_invoked "$log"

  pass "empty id or missing state dir refuses loudly and never rms a stray path"
}

test_happy_path_removes_only_check_and_trust() {
  local home out err status sibling meta
  home=$(make_home happy)
  out="$home/out.txt"
  err="$home/err.txt"
  sibling="$home/state/other.check.sh"
  meta="$home/state/demo-check.meta"
  write_registered_check "$home" demo-check
  printf '#!/usr/bin/env bash\nprintf other\n' > "$sibling"
  chmod 0700 "$sibling"
  printf 'keep-meta\n' > "$meta"
  assert_present "$home/state/demo-check.check.sh" "fixture check.sh missing before unregister"
  assert_present "$home/state/demo-check.check-trust" "fixture check-trust missing before unregister"

  status=0
  STATE='' ID='' FM_HOME="$home" "$UNREGISTER" demo-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "happy-path unregister"
  assert_contains "$(cat "$out")" "unregistered: state/demo-check.check.sh" \
    "happy path did not report unregistration"
  assert_absent "$home/state/demo-check.check.sh" "happy path left check.sh behind"
  assert_absent "$home/state/demo-check.check-trust" "happy path left check-trust behind"
  assert_present "$sibling" "happy path deleted a sibling check.sh"
  assert_present "$meta" "happy path deleted an unrelated state file"

  pass "happy path removes only the named check.sh and check-trust"
}

test_unsafe_hardlink_or_symlink_is_refused() {
  local home out err status alias
  home=$(make_home unsafe)
  out="$home/out.txt"
  err="$home/err.txt"
  write_registered_check "$home" custom
  alias="$home/custom-check.alias"
  ln "$home/state/custom.check.sh" "$alias"

  status=0
  FM_HOME="$home" "$UNREGISTER" custom >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister hard-linked check.sh"
  assert_contains "$(cat "$err")" "unsafe to remove" "hard-link refusal used the wrong stderr"
  assert_present "$home/state/custom.check.sh" "hard-link refusal deleted check.sh"
  assert_present "$home/state/custom.check-trust" "hard-link refusal deleted check-trust"
  assert_present "$alias" "hard-link refusal deleted the external alias"

  rm -f "$alias"
  rm -f "$home/state/custom.check.sh"
  printf '#!/usr/bin/env bash\nprintf target\n' > "$home/outside.check.sh"
  chmod 0700 "$home/outside.check.sh"
  ln -s "$home/outside.check.sh" "$home/state/custom.check.sh"

  status=0
  FM_HOME="$home" "$UNREGISTER" custom >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister symlink check.sh"
  assert_contains "$(cat "$err")" "unsafe to remove" "symlink refusal used the wrong stderr"
  assert_present "$home/state/custom.check.sh" "symlink refusal removed the state symlink"
  assert_present "$home/outside.check.sh" "symlink refusal deleted the external target"
  assert_present "$home/state/custom.check-trust" "symlink refusal deleted check-trust"

  pass "hard-linked or symlinked artifacts are refused and left in place"
}

# A fakebin that reproduces a Git for Windows noacl mount, measured on
# 2026-11-13: chmod succeeds without changing any mode, and `uname -s` reports
# the given kernel. A bare `uname` stays real, so the stat flavor the library
# picks still matches the host.
modeless_fakebin() {  # <home> <kernel>
  local home=$1 kernel=$2 fakebin real_uname
  fakebin=$(fm_fakebin "$home")
  real_uname=$(command -v uname)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/chmod"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = -s ] && { printf '%s\n' '$kernel'; exit 0; }
exec '$real_uname' "\$@"
SH
  "$(command -v chmod)" +x "$fakebin/chmod" "$fakebin/uname"
  printf '%s\n' "$fakebin"
}

test_registration_on_a_mount_that_cannot_store_modes() {
  local home fakebin status mode
  home=$(make_home modeless)
  printf '#!/usr/bin/env bash\nprintf custom-ready\n' > "$home/state/demo.check.sh"
  chmod 0644 "$home/state/demo.check.sh"
  mode=$(stat -c %a "$home/state/demo.check.sh" 2>/dev/null || /usr/bin/stat -f %Lp "$home/state/demo.check.sh")
  [ "$mode" != 700 ] || fail "fixture is vacuous: the check already has mode 700"

  # Off Windows an exact private mode stays required, whatever chmod does.
  fakebin=$(modeless_fakebin "$home" Linux)
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" demo >/dev/null 2>"$home/err" || status=$?
  expect_code 1 "$status" "register a mode-$mode check on a Linux kernel"
  assert_absent "$home/state/demo.check-trust" "a Linux kernel bound a check that is not mode 700"

  # A Cygwin-family kernel whose mount cannot store a mode accepts the same
  # file, and the watcher-side verdict agrees with the registration.
  fakebin=$(modeless_fakebin "$home" MINGW64_NT-10.0-26200)
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" demo >/dev/null 2>"$home/err" || status=$?
  expect_code 0 "$status" "register a mode-$mode check on a modeless Windows mount ($(cat "$home/err"))"
  PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" demo' _ "$ROOT" "$home/state" \
    || fail "the watcher did not trust a check registered on a modeless Windows mount"

  # A probe whose chmod fails proves nothing about the mount, so a Windows
  # kernel keeps the strict test and refuses the check itself.
  rm -f "$home/state/demo.check-trust"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/chmod"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" demo >/dev/null 2>"$home/err" || status=$?
  expect_code 1 "$status" "register a mode-$mode check on a Windows kernel whose probe chmod fails"
  grep -q 'custom check is unavailable' "$home/err" \
    || fail "a failed mode probe did not keep the strict test: $(cat "$home/err")"
  assert_absent "$home/state/demo.check-trust" "a failed mode probe bound a check that is not mode 700"

  # Where this host's own mount does store modes, a Windows kernel still gets
  # the strict test: a real chmod that takes effect leaves no excuse.
  chmod 0600 "$home/state/demo.check.sh"
  if [ "$(stat -c %a "$home/state/demo.check.sh" 2>/dev/null || /usr/bin/stat -f %Lp "$home/state/demo.check.sh")" = 600 ]; then
    rm -f "$home/state/demo.check-trust"
    status=0
    fakebin="$home/strict-bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = -s ] && { printf '%s\n' MINGW64_NT-10.0-26200; exit 0; }
exec '$(command -v uname)' "\$@"
SH
    chmod +x "$fakebin/uname"
    PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" demo >/dev/null 2>"$home/err" || status=$?
    expect_code 1 "$status" "register a mode-600 check on a Windows kernel whose mount stores modes"
  else
    printf 'note: this host mount cannot store modes; the strict-Windows case ran only through the fakes\n' >&2
  fi
  pass "custom check registration accepts a modeless Windows mount and stays strict everywhere else"
}

test_empty_id_and_empty_state_refuse_without_stray_rm
test_happy_path_removes_only_check_and_trust
test_registration_on_a_mount_that_cannot_store_modes
test_unsafe_hardlink_or_symlink_is_refused
