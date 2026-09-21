#!/usr/bin/env bash
# Behavior tests for fm-check-unregister.sh: refuse empty-variable retirement,
# and remove only the two named custom-check files on the happy path.
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

test_empty_id_and_empty_state_refuse_without_stray_rm
test_happy_path_removes_only_check_and_trust
test_unsafe_hardlink_or_symlink_is_refused
