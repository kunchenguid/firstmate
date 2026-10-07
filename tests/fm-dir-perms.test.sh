#!/usr/bin/env bash
# tests/fm-dir-perms.test.sh - behavior tests for bin/fm-dir-perms-lib.sh.
#
# These pin the incident this library exists for: a setgid temporary directory
# makes every directory created beneath it inherit the setgid bit and a naive
# `mkdir -m 700` (or a follow-up `chmod 700`) yields 2700. The tests replicate a
# 3777 scratch parent where the host filesystem supports it, then assert the
# owner-only contract normalizes the directory or refuses with a precise error.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dir-perms-lib.sh
. "$ROOT/bin/fm-dir-perms-lib.sh"

# Prefer a stable scratch parent when TMPDIR sits under an unsticky writable
# mount; a sticky /tmp can still hold disposable fixtures.
fixture_parent=$(fm_dir_namespace_parent "${TMPDIR:-/tmp}" fm-dir-perms-tests \
  || fm_dir_namespace_parent /tmp fm-dir-perms-tests) \
  || fail "no stable parent for directory permission fixtures"
TMP_ROOT=$(TMPDIR="$fixture_parent" fm_test_tmproot fm-dir-perms-tests)

# A sticky scratch parent that carries the setgid bit. On
# a host or filesystem that will not propagate setgid, the cases below still
# hold: the assertions are about the final mode, and the setgid pre-condition is
# only asserted where the platform actually reproduced it.
SG_ROOT="$TMP_ROOT/setgid-parent"
mkdir -p "$SG_ROOT"
chmod 3777 "$SG_ROOT"
# Prove the parent actually imposes setgid on a child, not merely that the
# parent itself is 3777: create a probe under umask 077 so mkdir's result is
# indistinguishable from `mkdir -m 700`, and confirm the child is 2700.
setgid_reproduced=0
if [ "$(fm_dir_perms_mode "$SG_ROOT")" = 3777 ]; then
  (umask 077; mkdir "$SG_ROOT/.probe") 2>/dev/null || true
  [ "$(fm_dir_perms_mode "$SG_ROOT/.probe")" = 2700 ] && setgid_reproduced=1
  rmdir "$SG_ROOT/.probe" 2>/dev/null || true
fi

mode_of() { fm_dir_perms_mode "$1"; }

test_mode_helpers_report() {
  local dir mode uid
  dir="$TMP_ROOT/mode-helpers"; mkdir -p "$dir"
  mode=$(mode_of "$dir") || fail "fm_dir_perms_mode failed on a readable directory"
  case "$mode" in ''|*[!0-7]*) fail "fm_dir_perms_mode returned a non-octal mode: '$mode'" ;; esac
  [ "${#mode}" -ge 3 ] || fail "fm_dir_perms_mode returned a short mode: '$mode'"
  uid=$(fm_dir_perms_uid "$dir") || fail "fm_dir_perms_uid failed on a readable directory"
  [ "$uid" = "$(id -u)" ] || fail "fm_dir_perms_uid reported $uid for the current user's directory"
  [ "$(fm_dir_perms_owner "$dir")" = "$mode/$uid" ] || fail "fm_dir_perms_owner did not compose mode/uid"
  if [ -k "$SG_ROOT" ]; then
    mode=$(mode_of "$SG_ROOT") || fail "fm_dir_perms_mode failed on a sticky directory"
    [ $((8#$mode & 01000)) -ne 0 ] || fail "fm_dir_perms_mode omitted a real sticky bit"
  fi
  if [ -g "$SG_ROOT" ]; then
    mode=$(mode_of "$SG_ROOT") || fail "fm_dir_perms_mode failed on a setgid directory"
    [ $((8#$mode & 02000)) -ne 0 ] || fail "fm_dir_perms_mode omitted a real setgid bit"
  fi
  mode=$(fm_dir_perms_mode "$TMP_ROOT/does-not-exist-$$") && fail "fm_dir_perms_mode succeeded on a missing directory"
  pass "dir perms helpers report portable mode and owner"
}

test_valid_tolerates_inherited_setgid() {
  local dir
  dir="$SG_ROOT/valid-tolerant"; mkdir -p "$dir"
  if [ "$setgid_reproduced" = 1 ]; then
    chmod 2700 "$dir"
    [ "$(mode_of "$dir")" = 2700 ] || fail "fixture could not be set to mode 2700"
  else
    chmod 700 "$dir"
  fi
  fm_dir_owner_only_valid "$dir" \
    || fail "an owner-only directory must validate, including inherited setgid where supported"
  pass "owner-only validation accepts the private directory (setgid case when supported)"
}

test_valid_rejects_group_or_other_access() {
  local dir
  dir="$SG_ROOT/valid-open"; mkdir -p "$dir"
  chmod 755 "$dir"
  fm_dir_owner_only_valid "$dir" && fail "a 0755 directory must not validate as owner-only"
  chmod 707 "$dir"
  fm_dir_owner_only_valid "$dir" && fail "a 0707 directory must not validate as owner-only"
  pass "owner-only validation rejects any group or other permission bit"
}

test_valid_rejects_symlink_and_non_directory() {
  local dir link file
  dir="$SG_ROOT/valid-real"; mkdir -p "$dir"; chmod 700 "$dir"
  link="$SG_ROOT/valid-link"; ln -s "$dir" "$link"
  fm_dir_owner_only_valid "$link" && fail "a symlink to a private directory must not validate"
  file="$SG_ROOT/valid-file"; : > "$file"; chmod 600 "$file"
  fm_dir_owner_only_valid "$file" && fail "a regular file must not validate as a directory"
  pass "owner-only validation rejects symlinks and non-directories"
}

test_ensure_creates_exactly_0700_under_setgid_parent() {
  local dir
  dir="$SG_ROOT/created"
  fm_dir_owner_only_ensure "$dir" "created namespace" \
    || fail "ensure refused to create a namespace under a setgid parent"
  [ "$(mode_of "$dir")" = 700 ] \
    || fail "ensure left mode $(mode_of "$dir"); a sticky setgid parent must not leak into the new directory"
  fm_dir_owner_only_valid "$dir" || fail "a created namespace must validate"
  pass "ensure creates exactly 0700 even under a 2777 parent"
}

test_ensure_repairs_a_previous_special_mode() {
  local dir
  if [ "$setgid_reproduced" = 1 ]; then
    dir="$SG_ROOT/repair-setgid"; mkdir -p "$dir"; chmod 2700 "$dir"
    fm_dir_owner_only_ensure "$dir" "repair setgid" \
      || fail "ensure refused to repair an existing 2700 namespace"
    [ "$(mode_of "$dir")" = 700 ] \
      || fail "ensure did not clear the inherited setgid bit (mode $(mode_of "$dir"))"
  fi
  dir="$SG_ROOT/repair-sticky"; mkdir -p "$dir"; chmod 700 "$dir"; chmod a-st "$dir"
  chmod +t "$dir" 2>/dev/null || true
  if [ "$(mode_of "$dir")" = 1700 ]; then
    fm_dir_owner_only_ensure "$dir" "repair sticky" \
      || fail "ensure refused to repair an existing 1700 namespace"
    [ "$(mode_of "$dir")" = 700 ] \
      || fail "ensure did not clear the sticky bit (mode $(mode_of "$dir"))"
  fi
  pass "ensure normalizes directory special bits where supported"
}

test_ensure_refuses_a_preexisting_open_mode() {
  local dir err rc
  dir="$SG_ROOT/refuse-open"; mkdir -p "$dir"; chmod 777 "$dir"
  local original_mode
  original_mode=$(mode_of "$dir")
  printf '%s\n' 'preexisting content' > "$dir/marker"
  err="$TMP_ROOT/refuse-open.err"
  rc=0
  fm_dir_owner_only_ensure "$dir" "open namespace" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ensure accepted a preexisting world-writable namespace"
  [ "$(mode_of "$dir")" = "$original_mode" ] \
    || fail "ensure changed a preexisting open namespace before refusing it"
  [ "$(cat "$dir/marker")" = 'preexisting content' ] \
    || fail "ensure changed content in a preexisting open namespace"
  assert_grep "not a private directory" "$err" "ensure did not explain the open-mode refusal"
  pass "ensure refuses a preexisting open namespace before changing its mode"
}

test_ensure_refuses_replaceable_parent() {
  local parent dir err rc
  parent="$TMP_ROOT/replaceable-parent"; mkdir -p "$parent"
  chmod 2777 "$parent"
  dir="$parent/private"
  err="$TMP_ROOT/replaceable-parent.err"
  rc=0
  fm_dir_owner_only_ensure "$dir" "replaceable namespace" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ensure created a namespace under an unsticky 2777 parent"
  [ ! -e "$dir" ] || fail "ensure created a namespace before refusing its parent"
  assert_grep "replaceable by another user" "$err" "ensure did not explain the unsafe parent"
  mkdir "$dir"; chmod 700 "$dir"
  rc=0
  fm_dir_owner_only_ensure "$dir" "replaceable namespace" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ensure accepted an existing namespace under an unsticky 2777 parent"
  pass "ensure refuses new and existing namespaces beneath a replaceable parent"
}

test_namespace_parent_chooses_stable_fallback() {
  local parent selected dir
  parent="$TMP_ROOT/unsticky-choice"; mkdir -p "$parent"
  chmod 2777 "$parent"
  selected=$(HOME="$TMP_ROOT" fm_dir_namespace_parent "$parent" fallback-test) \
    || fail "namespace parent could not use a stable home fallback"
  [ "$selected" = "$TMP_ROOT" ] || fail "namespace parent chose the replaceable temporary directory"
  dir="$selected/fallback-test"
  fm_dir_owner_only_ensure "$dir" "fallback namespace" || fail "fallback namespace could not be secured"
  [ "$(mode_of "$dir")" = 700 ] || fail "fallback namespace was not owner-only"
  selected=$(HOME="$TMP_ROOT" fm_dir_namespace_parent "$SG_ROOT" sticky-test) \
    || fail "namespace parent refused a sticky setgid directory"
  [ "$selected" = "$SG_ROOT" ] || fail "namespace parent needlessly left a stable temporary directory"
  pass "namespace parent uses a stable temporary directory or home fallback"
}

test_ensure_allows_symlinked_parent() {
  local parent link dir
  parent="$TMP_ROOT/real-parent"; mkdir -p "$parent"
  link="$TMP_ROOT/parent-link"; ln -s "$parent" "$link"
  dir="$link/private"
  fm_dir_owner_only_ensure "$dir" "symlinked-parent namespace" \
    || fail "ensure refused a symlinked parent such as macOS /tmp"
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    || fail "ensure did not create a plain directory through the symlinked parent"
  [ "$(mode_of "$dir")" = 700 ] \
    || fail "ensure did not secure the directory through a symlinked parent"
  pass "ensure accepts a symlinked parent while creating a plain private directory"
}

test_ensure_refuses_symlink_with_a_precise_error() {
  local dir link err rc
  dir="$SG_ROOT/refuse-real"; mkdir -p "$dir"; chmod 700 "$dir"
  link="$SG_ROOT/refuse-link"; ln -s "$dir" "$link"
  err="$TMP_ROOT/refuse-link.err"
  rc=0
  fm_dir_owner_only_ensure "$link" "refused namespace" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ensure accepted a symlink as the namespace"
  assert_grep "not a plain directory" "$err" "ensure did not explain the symlink refusal"
  pass "ensure refuses a symlink with a precise diagnostic"
}

test_ensure_refuses_a_missing_parent() {
  local err rc
  err="$TMP_ROOT/missing-parent.err"
  rc=0
  fm_dir_owner_only_ensure "$SG_ROOT/absent/deep" "missing-parent namespace" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ensure created a namespace whose parent does not exist"
  assert_grep "parent directory" "$err" "ensure did not explain the missing-parent refusal"
  pass "ensure refuses a missing parent with a precise diagnostic"
}

test_setgid_precondition_if_reproducible() {
  [ "$setgid_reproduced" = 1 ] \
    || { pass "setgid inheritance not reproduced on this host; normalization cases still covered"; return 0; }
  pass "scratch parent reproduced setgid inheritance"
}

test_mode_helpers_report
test_valid_tolerates_inherited_setgid
test_valid_rejects_group_or_other_access
test_valid_rejects_symlink_and_non_directory
test_ensure_creates_exactly_0700_under_setgid_parent
test_ensure_repairs_a_previous_special_mode
test_ensure_refuses_a_preexisting_open_mode
test_ensure_refuses_replaceable_parent
test_namespace_parent_chooses_stable_fallback
test_ensure_allows_symlinked_parent
test_ensure_refuses_symlink_with_a_precise_error
test_ensure_refuses_a_missing_parent
test_setgid_precondition_if_reproducible
